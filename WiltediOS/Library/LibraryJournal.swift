import Foundation
import OSLog
import WiltedCloudKitLibrary

private let journalLog = Logger(subsystem: "com.zerodelta.wilted", category: "Journal")

/// The iPhone's own record of what it was told and what it did (`Library/Logs/playback-journal.log`):
/// commands received, starts and stops with their positions, decisions, questions asked and
/// finished-here changes. The phone's unified log keeps a few hours; this file keeps about 2 MB.
/// Lines are `key=value` text and carry no owner token, account id or device id.
final class LibraryJournal: Sendable {
    let archive: CloudKitOperationArchive
    private let now: @Sendable () -> Date

    init(archive: CloudKitOperationArchive, now: @escaping @Sendable () -> Date = { Date() }) {
        self.archive = archive
        self.now = now
    }

    convenience init(url: URL, now: @escaping @Sendable () -> Date = { Date() }, maxBytes: Int = 1_000_000) {
        self.init(archive: CloudKitOperationArchive(url: url, maxBytes: maxBytes), now: now)
    }

    /// The standard journal under the app's `Library/Logs/playback-journal.log`.
    static func standard(fileManager: FileManager = .default, now: @escaping @Sendable () -> Date = { Date() }) -> LibraryJournal? {
        guard let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first else { return nil }
        let url = library.appendingPathComponent("Logs/playback-journal.log")
        return LibraryJournal(url: url, now: now)
    }

    /// Appends one timestamped line and sends the same line to the unified log. Never throws: a
    /// failed write is dropped. The protection class is set on every call (events are rare) so the
    /// file made after a rotation is also writable while the phone is locked in a car.
    func note(_ line: String) {
        let line = line.replacingOccurrences(of: "\n", with: " ")
        archive.append(line, at: now())
        LibraryFileProtection.apply(to: archive.url)
        journalLog.notice("\(line, privacy: .public)")
    }
}
