import Foundation
import OSLog
import WiltedCloudKitLibrary
import WiltedLibrary

private let journalLog = Logger(subsystem: "com.zerodelta.wilted", category: "PlaybackJournal")

/// The iPhone's version-2 playback record. Legacy `Library/Logs/playback-journal.log` is preserved
/// and is not read into this stream. New records contain only allowlisted state and a pseudonymous
/// item tag; the tag supports cross-device correlation but is not anonymous data.
final class LibraryJournal: Sendable {
    let archive: CloudKitOperationArchive
    private let now: @Sendable () -> Date
    private let logLine: @Sendable (String) -> Void

    init(
        url: URL,
        now: @escaping @Sendable () -> Date = { Date() },
        maxBytes: Int = 1_000_000,
        logLine: @escaping @Sendable (String) -> Void = { journalLog.notice("\($0, privacy: .public)") }
    ) {
        self.archive = CloudKitOperationArchive(url: url, maxBytes: maxBytes, requirePrivateFile: true)
        self.now = now
        self.logLine = logLine
    }

    /// The version-2 journal under the app's private `Library/Logs/playback-v2` directory.
    static func standard(fileManager: FileManager = .default, now: @escaping @Sendable () -> Date = { Date() }) -> LibraryJournal? {
        guard let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first else { return nil }
        let directory = library.appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("playback-v2", isDirectory: true)
        guard preparePrivateDirectory(at: directory, fileManager: fileManager) else { return nil }
        let url = directory.appendingPathComponent("playback-journal.log")
        return LibraryJournal(url: url, now: now)
    }

    /// Creates or tightens only the dedicated v2 journal directory, never its shared `Logs` parent.
    static func preparePrivateDirectory(at directory: URL, fileManager: FileManager = .default) -> Bool {
        do {
            try fileManager.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let attributes = try fileManager.attributesOfItem(atPath: directory.path)
            return (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700
        } catch {
            return false
        }
    }

    /// Appends a timestamped, allowlisted line and sends only event fields to public OSLog. Never
    /// throws: a failed write is dropped. The protection class is set on every call so a rotated
    /// file remains writable while the phone is locked in a car.
    func note(_ line: String) {
        let safeLine = PlaybackJournalPrivacy.sanitizeLegacyLine(line)
        append(safeLine, publicLine: PlaybackJournalPrivacy.publicLogLine(from: safeLine))
    }

    /// Appends a structured, cross-device correlatable record.
    func note(_ record: PlaybackJournalRecord) {
        append(record.line, publicLine: record.publicLogLine)
    }

    private func append(_ line: String, publicLine: String) {
        if archive.append(line, at: now()) { LibraryFileProtection.apply(to: archive.url) }
        logLine(publicLine)
    }
}
