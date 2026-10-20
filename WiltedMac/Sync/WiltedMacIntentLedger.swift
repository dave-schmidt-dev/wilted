import Foundation
import OSLog
import WiltedProducer

private let ledgerLog = Logger(subsystem: "com.zerodelta.wilted", category: "MacIntentLedger")

/// Durable record of the intent ids the Mac has begun applying.
///
/// An id is written to disk before the intent is applied, so an intent is applied at most once
/// even across a crash or restart (the server keeps every intent, so a fresh process sees
/// them all again). Entries older than `retention` are pruned; the media service ignores
/// intents older than its own age limit, which is shorter, so a pruned id never comes back.
actor WiltedMacIntentLedger {
    static let retention: TimeInterval = 30 * 24 * 60 * 60

    private struct Stored: Codable {
        var version = 1
        var recorded: [String: Date]
    }

    /// Writes the ledger's bytes durably to its file.
    typealias Writer = @Sendable (Data, URL) throws -> Void

    private let fileURL: URL?
    private let now: @Sendable () -> Date
    private let write: Writer
    private var recorded: [String: Date] = [:]

    /// `fileURL` nil keeps the ledger in memory only (tests). `write` is replaced only by tests
    /// that inject a failed save.
    init(
        fileURL: URL?, now: @escaping @Sendable () -> Date = { Date() },
        write: @escaping Writer = { try DurableFile.write($0, to: $1) }
    ) {
        self.fileURL = fileURL
        self.now = now
        self.write = write
        if let fileURL, let data = try? Data(contentsOf: fileURL) {
            if let stored = try? JSONDecoder().decode(Stored.self, from: data) {
                recorded = stored.recorded
            } else {
                // An unreadable ledger is set aside, not deleted, and the ledger starts empty.
                let aside = fileURL.appendingPathExtension("corrupt")
                try? FileManager.default.removeItem(at: aside)
                try? FileManager.default.moveItem(at: fileURL, to: aside)
                ledgerLog.error("Intent ledger was unreadable and was set aside")
            }
        }
        recorded = recorded.filter { $0.value > now().addingTimeInterval(-Self.retention) }
    }

    var count: Int { recorded.count }

    func contains(_ id: String) -> Bool { recorded[id] != nil }

    /// Records `id` durably and returns true when it was new. Throws, leaving the id
    /// unrecorded, only when the id did not reach the file: the caller must then not apply the
    /// intent, and a later call records it afresh.
    func recordIfNew(_ id: String) throws -> Bool {
        guard recorded[id] == nil else { return false }
        let pruned = recorded.filter { $0.value <= now().addingTimeInterval(-Self.retention) }.keys
        var next = recorded
        pruned.forEach { next[$0] = nil }
        next[id] = now()
        try persist(next)
        recorded = next
        return true
    }

    /// Drops entries older than the retention window; returns how many were dropped.
    @discardableResult
    func prune() throws -> Int {
        let cutoff = now().addingTimeInterval(-Self.retention)
        let next = recorded.filter { $0.value > cutoff }
        let dropped = recorded.count - next.count
        guard dropped > 0 else { return 0 }
        try persist(next)
        recorded = next
        return dropped
    }

    /// Writes `entries`, and succeeds whenever the file now holds them. A durable write renames
    /// the new file into place before it syncs the folder, so a failed folder sync leaves the
    /// entries on disk, where a restarted ledger reads them; reporting that as a failure would
    /// leave an id recorded that its caller never applies. The save is retried once to sync the
    /// folder again, and every later save syncs it too.
    private func persist(_ entries: [String: Date]) throws {
        guard let fileURL else { return }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Stored(recorded: entries))
        do {
            try write(data, fileURL)
        } catch {
            guard (try? Data(contentsOf: fileURL)) == data else { throw error }
            ledgerLog.warning("Intent ledger was saved but its folder sync failed: \(String(describing: error), privacy: .public)")
            do {
                try write(data, fileURL)
            } catch {
                ledgerLog.warning("Intent ledger folder sync failed again; the next save retries it: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
