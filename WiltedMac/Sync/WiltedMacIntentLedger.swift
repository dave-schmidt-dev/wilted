import Foundation
import OSLog

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

    private let fileURL: URL?
    private let now: @Sendable () -> Date
    private var recorded: [String: Date] = [:]

    /// `fileURL` nil keeps the ledger in memory only (tests).
    init(fileURL: URL?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.fileURL = fileURL
        self.now = now
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
    /// unrecorded, when the write fails: the caller must then not apply the intent.
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

    private func persist(_ entries: [String: Date]) throws {
        guard let fileURL else { return }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Stored(recorded: entries))
        try data.write(to: fileURL, options: .atomic)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            try? handle.synchronize()
            try? handle.close()
        }
    }
}
