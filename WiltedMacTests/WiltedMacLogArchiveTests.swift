import Foundation
import OSLog
import XCTest
@testable import WiltedMac

@MainActor
final class WiltedMacLogArchiveTests: XCTestCase {
    func testSizeCapKeepsFilesBoundedAndDropsOldestBackup() throws {
        let file = try makeFile("size-cap", maximumBytes: 256, backupCount: 2)
        let appended = makeLines(count: 200)

        for start in stride(from: 0, to: appended.count, by: 40) {
            try file.append(Array(appended[start..<min(start + 40, appended.count)]))
        }

        let existing = archiveURLs(for: file)
        let sizes = try existing.map { try fileSize($0) }
        XCTAssertFalse(existing.isEmpty)
        for (url, size) in zip(existing, sizes) {
            XCTAssertLessThanOrEqual(size, 256, url.lastPathComponent)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.backupURL(3).path))
        XCTAssertLessThanOrEqual(sizes.reduce(0, +), 3 * 256)
    }

    func testRotationKeepsContiguousSuffixInBackupOrder() throws {
        let file = try makeFile("rotation-order", maximumBytes: 256, backupCount: 2)
        let appended = makeLines(count: 200)

        for start in stride(from: 0, to: appended.count, by: 40) {
            try file.append(Array(appended[start..<min(start + 40, appended.count)]))
        }

        var archived: [String] = []
        for index in [2, 1] {
            let url = file.backupURL(index)
            if FileManager.default.fileExists(atPath: url.path) {
                archived.append(contentsOf: try lines(at: url))
            }
        }
        archived.append(contentsOf: try lines(at: file.url))

        let firstArchived = try XCTUnwrap(archived.first)
        let suffixStart = try XCTUnwrap(appended.firstIndex(of: firstArchived))
        XCTAssertEqual(Array(appended[suffixStart...]), archived)
        XCTAssertEqual(archived.last, appended.last)
        XCTAssertLessThan(archived.count, appended.count)
        XCTAssertFalse(archived.contains(appended[0]))
    }

    func testOversizedExistingFileIsTrimmedAsItRotates() throws {
        let directory = try makeDirectory("oversized-existing")
        let url = directory.appendingPathComponent("wilted.log")
        let oldLines = (0..<20).map { "old-entry-\($0)-" + String(repeating: "o", count: 8) }
        try Data((oldLines.joined(separator: "\n") + "\n").utf8).write(to: url)
        let file = WiltedMacRotatingLogFile(url: url, maximumBytes: 256, backupCount: 2)

        let newLine = "new-entry-after-rotation"
        try file.append([newLine])

        let backup = try lines(at: file.backupURL(1))
        XCTAssertLessThanOrEqual(try fileSize(file.backupURL(1)), 256)
        XCTAssertFalse(backup.isEmpty)
        XCTAssertEqual(backup, Array(oldLines.suffix(backup.count)))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), newLine + "\n")
    }

    func testOversizedLineIsCapped() throws {
        let file = try makeFile("oversized-line", maximumBytes: 256, backupCount: 2)

        try file.append([String(repeating: "z", count: 1000)])

        let existing = archiveURLs(for: file)
        XCTAssertFalse(existing.isEmpty)
        for url in existing {
            XCTAssertLessThanOrEqual(try fileSize(url), 256, url.lastPathComponent)
        }
    }

    func testPassArchivesOnlyWiltedErrorsAndFaults() async throws {
        let file = try makeFile("level-filter", maximumBytes: 100_000, backupCount: 2)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let debug = makeEntry("level-debug-marker", date: base, level: .debug)
        let info = makeEntry("level-info-marker", date: base.addingTimeInterval(1), level: .info)
        let notice = makeEntry("level-notice-marker", date: base.addingTimeInterval(2), level: .notice)
        let error = makeEntry("level-error-marker", date: base.addingTimeInterval(3), level: .error)
        let fault = makeEntry("level-fault-marker", date: base.addingTimeInterval(4), level: .fault)
        let otherError = makeEntry(
            "level-apple-marker", date: base.addingTimeInterval(5), level: .error,
            subsystem: "com.apple.example"
        )
        let box = LockedLogEntries([debug, info, notice, error, fault, otherError])
        let archive = WiltedMacLogArchive(file: file, source: { box.snapshot })

        let written = await archive.archivePass()

        XCTAssertEqual(written, 2)
        let rendered = try lines(at: file.url)
        XCTAssertEqual(rendered.count, 2)
        XCTAssertTrue(rendered.contains { $0.contains("level-error-marker") })
        XCTAssertTrue(rendered.contains { $0.contains("level-fault-marker") })
        for marker in ["level-debug-marker", "level-info-marker", "level-notice-marker", "level-apple-marker"] {
            XCTAssertFalse(rendered.contains { $0.contains(marker) }, marker)
        }
        XCTAssertNil(WiltedMacLogLine.render(debug))
        XCTAssertNil(WiltedMacLogLine.render(info))
        XCTAssertNil(WiltedMacLogLine.render(notice))
        XCTAssertNotNil(WiltedMacLogLine.render(error))
        XCTAssertNotNil(WiltedMacLogLine.render(fault))
    }

    func testRenderingAppliesPrivacyAnnotations() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000.125)
        let entry = WiltedMacLogArchiveEntry(
            date: date,
            level: .error,
            subsystem: "com.zerodelta.wilted.mac",
            category: "Privacy",
            components: [
                .init(literal: "public=", placeholder: "%{public}s",
                      argument: .string("privacy-public-value")),
                .init(literal: " default=", placeholder: "%s",
                      argument: .string("privacy-default-secret")),
                .init(literal: " private=", placeholder: "%{private}s",
                      argument: .string("privacy-private-secret")),
                .init(literal: " masked=", placeholder: "%{private,mask.hash}s",
                      argument: .string("privacy-mask-secret")),
                .init(literal: " sensitive=", placeholder: "%{sensitive}s",
                      argument: .string("privacy-sensitive-secret")),
                .init(literal: " redacted=", placeholder: "%{public}@",
                      argument: .redacted),
                .init(literal: " signed=", placeholder: "%ld",
                      argument: .signed(-42)),
                .init(literal: " privateSigned=", placeholder: "%{private}ld",
                      argument: .signed(99)),
                .init(literal: " unsigned=", placeholder: "%{public}lu",
                      argument: .unsigned(7)),
                .init(literal: " double=", placeholder: "%f",
                      argument: .double(2.5)),
                .init(literal: " bool=", placeholder: "%{bool}d",
                      argument: .signed(1)),
                .init(literal: " publicData=", placeholder: "%{public}@",
                      argument: .data),
                .init(literal: " defaultData=", placeholder: "%@",
                      argument: .data),
                .init(literal: " escaped=first line\nsecond\tline", placeholder: "",
                      argument: .none),
            ]
        )

        let rendered = try XCTUnwrap(WiltedMacLogLine.render(entry))
        let expectedMessage = "public=privacy-public-value default=<private> private=<private> "
            + "masked=<private> sensitive=<private> redacted=<private> signed=-42 "
            + "privateSigned=<private> unsigned=7 double=2.5 bool=true "
            + "publicData=<data> defaultData=<private> escaped=first line\\nsecond\\tline"
        XCTAssertEqual(
            rendered,
            "2023-11-14T22:13:20.125Z error com.zerodelta.wilted.mac Privacy: \(expectedMessage)"
        )
        XCTAssertFalse(rendered.contains("\n"))
        XCTAssertFalse(rendered.contains("\t"))
        for secret in [
            "privacy-default-secret", "privacy-private-secret", "privacy-mask-secret",
            "privacy-sensitive-secret",
        ] {
            XCTAssertFalse(rendered.contains(secret), secret)
        }
    }

    func testRenderingTruncatesLongLines() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let longEntry = makeEntry(String(repeating: "a", count: 5_000), date: date)

        let truncated = try XCTUnwrap(WiltedMacLogLine.render(longEntry))

        XCTAssertLessThanOrEqual(truncated.utf8.count, WiltedMacLogLine.maximumBytes)
        XCTAssertTrue(truncated.hasSuffix(" [truncated]"))
    }

    func testPassesAppendEachEntryOnce() async throws {
        let file = try makeFile("pass-cursor", maximumBytes: 100_000, backupCount: 2)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let first = makeEntry("once-first-marker", date: base)
        let second = makeEntry("once-second-marker", date: base.addingTimeInterval(1))
        let box = LockedLogEntries([first, second])
        let archive = WiltedMacLogArchive(file: file, source: { box.snapshot })

        let firstCount = await archive.archivePass()
        XCTAssertEqual(firstCount, 2)
        let secondCount = await archive.archivePass()
        XCTAssertEqual(secondCount, 0)

        box.replace(with: [
            first,
            second,
            makeEntry("once-same-date-marker", date: second.date),
            makeEntry("once-newer-marker", date: second.date.addingTimeInterval(1)),
        ])
        let thirdCount = await archive.archivePass()
        XCTAssertEqual(thirdCount, 2)

        let rendered = try lines(at: file.url)
        XCTAssertEqual(rendered.count, 4)
        for marker in [
            "once-first-marker", "once-second-marker", "once-same-date-marker", "once-newer-marker",
        ] {
            XCTAssertEqual(rendered.filter { $0.contains(marker) }.count, 1, marker)
        }
    }

    func testFailedWriteRetriesOnNextPass() async throws {
        let directory = try makeDirectory("failed-write")
        let blockingURL = directory.appendingPathComponent("logs")
        try Data("blocking".utf8).write(to: blockingURL)
        let file = WiltedMacRotatingLogFile(
            url: blockingURL.appendingPathComponent("wilted.log"),
            maximumBytes: 1024,
            backupCount: 2
        )
        let marker = "failed-write-marker"
        let box = LockedLogEntries([makeEntry(marker, date: Date(timeIntervalSince1970: 1_700_000_000))])
        let archive = WiltedMacLogArchive(file: file, source: { box.snapshot })

        let failed = await archive.archivePass()
        XCTAssertEqual(failed, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))

        try FileManager.default.removeItem(at: blockingURL)
        let retried = await archive.archivePass()
        XCTAssertEqual(retried, 1)
        XCTAssertTrue(try lines(at: file.url).contains { $0.contains(marker) })
    }

    func testCurrentProcessSourceArchivesWarningRoundTrip() async throws {
        let marker = UUID().uuidString
        let secret = UUID().uuidString
        let logger = Logger(
            subsystem: "com.zerodelta.wilted.mac.tests",
            category: "LogArchiveTests"
        )
        logger.warning("log archive probe \(marker, privacy: .public) \(secret)")

        let file = try makeFile("real-store", maximumBytes: 8_388_608, backupCount: 3)
        let archive = WiltedMacLogArchive(
            file: file,
            source: WiltedMacLogArchive.currentProcessSource()
        )
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        var markerLine: String?

        while ContinuousClock.now < deadline {
            _ = await archive.archivePass()
            let contents = try archiveURLs(for: file).map {
                try String(contentsOf: $0, encoding: .utf8)
            }
            let found = contents.joined(separator: "\n")
                .split(separator: "\n")
                .map(String.init)
                .first { $0.contains(marker) }
            if let found = found {
                markerLine = found
                break
            }
            try await Task.sleep(for: .milliseconds(200))
        }

        let line = try XCTUnwrap(markerLine, "the warning line was archived")
        XCTAssertTrue(line.contains("<private>"), "the default-privacy secret is redacted")
        for url in archiveURLs(for: file) {
            let contents = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(contents.contains(secret), "the private secret is not archived")
        }
    }

    func testWriteFailingMidPassIsRetriedWithoutDuplicates() async throws {
        let file = try makeFile("mid-pass-failure", maximumBytes: 256, backupCount: 2)
        let directory = file.url.deletingLastPathComponent()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let markers = ["mid-a-marker", "mid-b-marker", "mid-c-marker", "mid-d-marker"]
        let entries = markers.enumerated().map { makeEntry($1, date: base.addingTimeInterval(Double($0))) }
        let box = LockedLogEntries([entries[0]])
        let archive = WiltedMacLogArchive(file: file, source: { box.snapshot })
        let firstCount = await archive.archivePass()
        XCTAssertEqual(firstCount, 1)

        // Appending to the open file still works; the rotation rename does not.
        box.replace(with: entries)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        let blocked: Int
        do {
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
            blocked = await archive.archivePass()
        }
        XCTAssertGreaterThan(blocked, 0)
        XCTAssertLessThan(blocked, 3)

        let retried = await archive.archivePass()
        XCTAssertEqual(blocked + retried, 3)
        let archived = try archiveURLs(for: file).flatMap { try lines(at: $0) }
        for marker in markers {
            XCTAssertEqual(archived.filter { $0.contains(marker) }.count, 1, marker)
        }
    }

    func testShortWriteIsRolledBackBeforeRetry() async throws {
        let failNext = LockedFlag()
        let file = WiltedMacRotatingLogFile(
            url: try makeDirectory("short-write").appendingPathComponent("wilted.log"),
            maximumBytes: 100_000, backupCount: 2
        ) { handle, data in
            guard !failNext.take() else {
                try handle.write(contentsOf: data.prefix(data.count / 2))
                throw CocoaError(.fileWriteOutOfSpace)
            }
            try handle.write(contentsOf: data)
        }
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let first = makeEntry("short-first-marker", date: base)
        let second = makeEntry("short-second-marker", date: base.addingTimeInterval(1))
        let box = LockedLogEntries([first])
        let archive = WiltedMacLogArchive(file: file, source: { box.snapshot })
        let firstCount = await archive.archivePass()
        XCTAssertEqual(firstCount, 1)

        box.replace(with: [first, second])
        failNext.set()
        let failedCount = await archive.archivePass()
        XCTAssertEqual(failedCount, 0)
        let retriedCount = await archive.archivePass()
        XCTAssertEqual(retriedCount, 1)

        let expected = [first, second].compactMap { WiltedMacLogLine.render($0) }
        XCTAssertEqual(try lines(at: file.url), expected)
    }

    func testLateEntryWithinLatenessIsWrittenOnce() async throws {
        let file = try makeFile("late-entry", maximumBytes: 100_000, backupCount: 2)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let early = makeEntry("late-early-marker", date: base.addingTimeInterval(10))
        let newest = makeEntry("late-newest-marker", date: base.addingTimeInterval(100))
        let box = LockedLogEntries([early, newest])
        let archive = WiltedMacLogArchive(file: file, source: { box.snapshot })
        let firstCount = await archive.archivePass()
        XCTAssertEqual(firstCount, 2)

        let late = makeEntry("late-arrival-marker", date: base.addingTimeInterval(90))
        let tooLate = makeEntry("late-expired-marker", date: base.addingTimeInterval(100 - WiltedMacLogArchive.lateness - 1))
        box.replace(with: [early, tooLate, late, newest])
        let secondCount = await archive.archivePass()
        XCTAssertEqual(secondCount, 1)
        let thirdCount = await archive.archivePass()
        XCTAssertEqual(thirdCount, 0)

        let rendered = try lines(at: file.url)
        XCTAssertEqual(rendered.filter { $0.contains("late-arrival-marker") }.count, 1)
        XCTAssertFalse(rendered.contains { $0.contains("late-expired-marker") })
    }

    func testSameTimestampEntryAheadInSourceOrderIsWrittenOnce() async throws {
        let file = try makeFile("same-date-order", maximumBytes: 100_000, backupCount: 2)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let first = makeEntry("order-first-marker", date: date)
        let box = LockedLogEntries([first])
        let archive = WiltedMacLogArchive(file: file, source: { box.snapshot })
        let firstCount = await archive.archivePass()
        XCTAssertEqual(firstCount, 1)

        box.replace(with: [makeEntry("order-ahead-marker", date: date), first])
        let secondCount = await archive.archivePass()
        XCTAssertEqual(secondCount, 1)

        let rendered = try lines(at: file.url)
        for marker in ["order-first-marker", "order-ahead-marker"] {
            XCTAssertEqual(rendered.filter { $0.contains(marker) }.count, 1, marker)
        }
    }

    func testNaNArgumentEntryIsWrittenOnce() async throws {
        let file = try makeFile("nan-entry", maximumBytes: 100_000, backupCount: 2)
        let entry = WiltedMacLogArchiveEntry(
            date: Date(timeIntervalSince1970: 1_700_000_000),
            level: .error,
            subsystem: "com.zerodelta.wilted.mac",
            category: "ArchiveTests",
            components: [.init(literal: "nan-marker position=", placeholder: "%f", argument: .double(.nan))]
        )
        let archive = WiltedMacLogArchive(file: file, source: { [entry] })

        let firstCount = await archive.archivePass()
        let secondCount = await archive.archivePass()

        XCTAssertEqual(firstCount, 1)
        XCTAssertEqual(secondCount, 0)
        XCTAssertEqual(try lines(at: file.url).filter { $0.contains("nan-marker") }.count, 1)
    }

    private func makeDirectory(_ name: String) throws -> URL {
        let directory = wiltedTemporaryDirectory("log-archive-\(name)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeFile(
        _ name: String,
        maximumBytes: Int,
        backupCount: Int
    ) throws -> WiltedMacRotatingLogFile {
        WiltedMacRotatingLogFile(
            url: try makeDirectory(name).appendingPathComponent("wilted.log"),
            maximumBytes: maximumBytes,
            backupCount: backupCount
        )
    }

    private func makeLines(count: Int) -> [String] {
        (0..<count).map { index in
            "archive-line-\(index)-" + String(repeating: "x", count: 24)
        }
    }

    private func makeEntry(
        _ marker: String,
        date: Date,
        level: WiltedMacLogArchiveEntry.Level = .error,
        subsystem: String = "com.zerodelta.wilted.mac"
    ) -> WiltedMacLogArchiveEntry {
        WiltedMacLogArchiveEntry(
            date: date,
            level: level,
            subsystem: subsystem,
            category: "ArchiveTests",
            components: [
                WiltedMacLogArchiveEntry.Component(
                    literal: marker,
                    placeholder: "",
                    argument: WiltedMacLogArchiveEntry.Argument.none
                ),
            ]
        )
    }

    private func fileSize(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.intValue ?? 0
    }

    private func lines(at url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
    }

    private func archiveURLs(for file: WiltedMacRotatingLogFile) -> [URL] {
        let backups = (1...max(1, file.backupCount)).map { file.backupURL($0) }
        return ([file.url] + backups).filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }
}

private final class LockedLogEntries: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [WiltedMacLogArchiveEntry]

    init(_ entries: [WiltedMacLogArchiveEntry]) {
        self.entries = entries
    }

    var snapshot: [WiltedMacLogArchiveEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    func replace(with entries: [WiltedMacLogArchiveEntry]) {
        lock.lock()
        defer { lock.unlock() }
        self.entries = entries
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() { lock.withLock { value = true } }

    /// Returns whether the flag was set, and clears it.
    func take() -> Bool {
        lock.withLock {
            defer { value = false }
            return value
        }
    }
}
