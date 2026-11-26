import Foundation
import XCTest
@testable import WiltedCloudKitLibrary

final class CloudKitOperationArchivePrivacyTests: XCTestCase {
    func testRequiredPrivateArchiveSecuresExistingFilesBeforeAppending() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloudkit-private-archive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sharedLogs = root.appendingPathComponent("Logs", isDirectory: true)
        let privateDirectory = sharedLogs.appendingPathComponent("playback-v2", isDirectory: true)
        try FileManager.default.createDirectory(at: privateDirectory, withIntermediateDirectories: true)
        let url = privateDirectory.appendingPathComponent("playback-journal.log")
        let backup = url.appendingPathExtension("1")
        try Data("preserved current row\n".utf8).write(to: url)
        try Data("preserved backup row\n".utf8).write(to: backup)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sharedLogs.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: privateDirectory.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: backup.path)
        let archive = CloudKitOperationArchive(url: url, requirePrivateFile: true)

        XCTAssertTrue(archive.append("event=pause", at: Date(timeIntervalSince1970: 1_700_000_000)))

        XCTAssertEqual(try mode(sharedLogs), 0o755, "the shared Logs parent keeps its existing mode")
        XCTAssertEqual(try mode(privateDirectory), 0o700)
        XCTAssertEqual(try mode(url), 0o600)
        XCTAssertEqual(try mode(backup), 0o600)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).hasPrefix("preserved current row\n"))
        XCTAssertTrue(try String(contentsOf: backup, encoding: .utf8).hasPrefix("preserved backup row\n"))
    }

    func testRequiredPrivateArchiveFailsClosedWhenDirectoryCannotBeCreated() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloudkit-private-archive-blocked-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("blocking parent".utf8).write(to: root)
        let url = root.appendingPathComponent("playback-v2/playback-journal.log")
        let archive = CloudKitOperationArchive(url: url, requirePrivateFile: true)

        XCTAssertFalse(archive.append("event=pause", at: Date(timeIntervalSince1970: 1_700_000_000)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    private func mode(_ url: URL) throws -> Int? {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue
    }
}
