import Foundation
import WiltedDomain

/// Measures the network bytes one podcast enclosure download attempt actually
/// receives, for the lifetime `receivedBytes` total.
///
/// - Every chunk is counted when it arrives, before size, hash or media
///   validation, so partial, rejected, failed and cancelled transfers count
///   what crossed the network.
/// - Each `download` call that transfers is its own attempt with a fresh owner
///   key, `download|<episode>|<nonce>`. A retry or a resumed download (the
///   coordinator never sends HTTP Range requests, so it re-fetches) counts its
///   own bytes. Reusing a verified file on disk transfers nothing and records
///   nothing.
/// - The attempt's cumulative count is written at most once per
///   `flushInterval` while bytes arrive, then once more on every exit path.
///   The store admits only what exceeds the attempt's high-water mark, so a
///   repeated write never double counts.
///
/// Crash-tail bound: a process that dies mid-transfer loses at most the bytes
/// received in the last second. Only podcast enclosure downloads are measured.
struct PodcastDownloadByteMeter: Sendable {
    /// The longest interval between persisted checkpoints while bytes arrive.
    static let flushInterval: TimeInterval = 1

    let ownerKey: String
    private(set) var receivedBytes: Int64 = 0
    private(set) var persistedBytes: Int64 = 0
    private var lastFlushAt: Date

    init(episodeID: ItemID, startedAt: Date, nonce: UUID = UUID()) {
        ownerKey = "download|\(episodeID.rawValue)|\(nonce.uuidString.lowercased())"
        lastFlushAt = startedAt
    }

    /// Counts one received chunk.
    mutating func receive(_ byteCount: Int) {
        guard byteCount > 0 else { return }
        let (sum, overflow) = receivedBytes.addingReportingOverflow(Int64(byteCount))
        receivedBytes = overflow ? .max : sum
    }

    /// The cumulative amount to write now, if a periodic write is due: at
    /// least `flushInterval` since the last one and something new to admit.
    /// Taking it starts the next interval whether or not the write succeeds.
    mutating func takeDueCheckpoint(at now: Date) -> LifetimeMeasureAmount? {
        guard now.timeIntervalSince(lastFlushAt) >= Self.flushInterval else { return nil }
        guard let amount = pendingAmount else { return nil }
        lastFlushAt = now
        return amount
    }

    /// The cumulative amount a terminal write must admit, if any.
    var pendingAmount: LifetimeMeasureAmount? {
        guard receivedBytes > persistedBytes else { return nil }
        return LifetimeMeasureAmount.bytes(.receivedBytes, count: receivedBytes)
    }

    /// Notes that the store admitted `amount`. A failed write leaves the mark
    /// alone, so the next, larger checkpoint still covers those bytes.
    mutating func didPersist(_ amount: LifetimeMeasureAmount) {
        persistedBytes = max(persistedBytes, amount.baseUnits)
    }
}
