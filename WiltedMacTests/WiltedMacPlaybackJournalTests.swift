import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltedMac

private final class PlaybackJournalSink: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var lines: [String] { lock.withLock { stored } }
    func append(_ line: String) { lock.withLock { stored.append(line) } }
}

@MainActor
final class WiltedMacPlaybackJournalTests: XCTestCase {
    func testMacJournalWritesAndLogsTheSamePrivacySafeRecord() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-playback-journal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("logs/playback-v2/playback-journal.log")
        let sink = PlaybackJournalSink()
        let journal = WiltedMacPlaybackJournal(
            url: url,
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            logLine: { sink.append($0) })
        let itemID = try ItemID(rawValue: "private-mac-item-712c")
        let record = PlaybackJournalRecord(
            source: .mac, event: .peerCheckpoint, itemID: itemID,
            positionSeconds: 123.4, epoch: 9, result: .observed, isPlaying: false)

        journal.note(record)

        let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines).filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 1)
        let body = try XCTUnwrap(lines.first).components(separatedBy: " ").dropFirst().joined(separator: " ")
        XCTAssertEqual(body, record.line)
        XCTAssertEqual(sink.lines, [record.publicLogLine], "the OSLog sink receives only public event fields")
        XCTAssertTrue(body.contains("item=\(PlaybackJournalRecord.itemTag(itemID))"))
        XCTAssertTrue(body.contains("epoch=9 position=123.4") || body.contains("position=123.4 epoch=9"))
        XCTAssertFalse(lines.joined().contains(itemID.rawValue))
        XCTAssertFalse(sink.lines.joined().contains(itemID.rawValue))
        XCTAssertFalse(sink.lines.joined().contains(PlaybackJournalRecord.itemTag(itemID)))
        XCTAssertFalse(sink.lines.joined().contains("position=123.4"))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testMacJournalTightensExistingV2FilesBeforeAppend() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-playback-journal-existing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let directory = folder.appendingPathComponent("logs/playback-v2", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("playback-journal.log")
        let backup = directory.appendingPathComponent("playback-journal-1.log")
        try Data("preserved old row\n".utf8).write(to: url)
        try Data("preserved backup row\n".utf8).write(to: backup)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: backup.path)
        let journal = WiltedMacPlaybackJournal(url: url, logLine: { _ in })

        journal.note(PlaybackJournalRecord(source: .mac, event: .pause, result: .paused))

        let folderPermissions = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        let filePermissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        let backupPermissions = try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(folderPermissions?.intValue, 0o700)
        XCTAssertEqual(filePermissions?.intValue, 0o600)
        XCTAssertEqual(backupPermissions?.intValue, 0o600)
        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(contents.hasPrefix("preserved old row\n"), "tightening permissions must preserve old evidence")
        XCTAssertTrue(contents.contains("event=pause"))
    }

    func testMacJournalDoesNotWriteWhenPrivateDirectoryCannotBeCreated() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-playback-journal-blocked-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("blocking parent".utf8).write(to: folder)
        let url = folder.appendingPathComponent("logs/playback-v2/playback-journal.log")
        let sink = PlaybackJournalSink()
        let journal = WiltedMacPlaybackJournal(url: url, logLine: { sink.append($0) })
        let itemID = try ItemID(rawValue: "private-blocked-item")

        journal.note(PlaybackJournalRecord(source: .mac, event: .pause, itemID: itemID, positionSeconds: 42))

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(sink.lines.count, 1)
        XCTAssertTrue(sink.lines[0].contains("event=pause"))
        XCTAssertFalse(sink.lines[0].contains(itemID.rawValue))
        XCTAssertFalse(sink.lines[0].contains(PlaybackJournalRecord.itemTag(itemID)))
        XCTAssertFalse(sink.lines[0].contains("position=42"))
    }
}
