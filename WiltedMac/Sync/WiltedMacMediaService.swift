import Foundation
import OSLog
import WiltedDomain
import WiltedLibrary

#if canImport(WiltedProducer)
import WiltedProducer
#endif

private let mediaLog = Logger(subsystem: "com.zerodelta.wilted", category: "MacMedia")

/// A ready revision the Mac holds for an entry, with the file that carries its audio.
struct WiltedMacReadyAudio: Sendable, Equatable {
    var revisionID: RevisionID
    var contentHash: String
    var byteCount: Int64
    var mediaType: String
    var durationSeconds: Double
    var fileURL: URL
}

/// Read-only view of what the Mac has ready. It never starts or triggers preparation.
protocol WiltedMacReadyAudioSource: Sendable {
    func readyAudio(for entryID: ItemID) async throws -> WiltedMacReadyAudio?
}

#if canImport(WiltedProducer)
/// `WiltedMacReadyAudioSource` over the existing one-read library snapshot.
struct WiltedMacLocalReadyAudioSource: WiltedMacReadyAudioSource {
    let store: LocalLibraryStore

    func readyAudio(for entryID: ItemID) async throws -> WiltedMacReadyAudio? {
        guard let stored = try await store.podcastLibrarySnapshot().readyRevisions[entryID] else { return nil }
        let revision = stored.revision
        return WiltedMacReadyAudio(
            revisionID: revision.revisionID, contentHash: revision.contentHash, byteCount: revision.byteCount,
            mediaType: revision.mediaType, durationSeconds: revision.durationSeconds, fileURL: stored.mediaURL
        )
    }
}
#endif

/// Serves `requestMedia` and retires assets, on the Mac only.
///
/// A request finds the entry's ready revision (read only), uploads it through
/// `publishMedia`, or publishes `notReady` when there is none; nothing here ever prepares
/// audio or writes producer state (W-INV-005). Accounting is per (entryID, revisionID): the
/// asset is withdrawn once every device that requested that revision has sent
/// `mediaCached` for it, or seven days after its last request. The transport holds one asset
/// per entry, so a newer revision replaces the older asset on upload; the older revision's
/// accounting then only drops its books and never withdraws the newer asset.
actor WiltedMacMediaService {
    static let timeToLive: TimeInterval = 7 * 24 * 60 * 60
    /// An intent older than this is stale and ignored.
    static let maximumIntentAge: TimeInterval = 7 * 24 * 60 * 60
    /// Mirrors the transport limit so an oversize file is answered `notReady` up front.
    static let maximumByteCount: Int64 = 250 * 1024 * 1024

    struct AssetKey: Hashable, Codable, Sendable {
        var entryID: String
        var revisionID: String
    }

    struct AssetRecord: Codable, Sendable, Equatable {
        var key: AssetKey
        var requesters: Set<String>
        var acked: Set<String>
        /// Last time a device asked for this revision; the seven days run from here.
        var touchedAt: Date

        var isComplete: Bool { !requesters.isEmpty && requesters.isSubset(of: acked) }
    }

    private struct Stored: Codable {
        var version = 1
        var records: [AssetRecord]
        /// Entry id to the revision currently on the transport.
        var published: [String: String]
    }

    private let source: any WiltedMacReadyAudioSource
    private let transport: any LibraryTransport
    private let accountingURL: URL?
    private let now: @Sendable () -> Date
    private var records: [AssetKey: AssetRecord] = [:]
    private var published: [String: String] = [:]
    private var tail: Task<Void, Never>?
    private(set) var lastFailure: String?

    init(
        source: any WiltedMacReadyAudioSource, transport: any LibraryTransport, accountingURL: URL?,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.source = source
        self.transport = transport
        self.accountingURL = accountingURL
        self.now = now
        if let accountingURL, let data = try? Data(contentsOf: accountingURL),
           let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            records = Dictionary(stored.records.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
            published = stored.published
        }
    }

    // MARK: - Entry points (serialized: one upload or withdrawal at a time)

    /// Applies one media intent; other intents are ignored.
    func handle(_ intent: LibraryIntent) async {
        await serialized { await self.process(intent) }
    }

    /// Withdraws every asset that has passed its seven days, and retries pending withdrawals.
    func sweepExpired() async {
        await serialized { await self.cleanup() }
    }

    /// True while the transport holds the asset for exactly this revision on the Mac's books.
    func isHolding(entryID: ItemID, revisionID: RevisionID) -> Bool {
        published[entryID.rawValue] == revisionID.rawValue
            && records[AssetKey(entryID: entryID.rawValue, revisionID: revisionID.rawValue)] != nil
    }

    var accountedAssetCount: Int { records.count }

    private func serialized(_ work: @escaping @Sendable () async -> Void) async {
        let previous = tail
        let task = Task {
            await previous?.value
            await work()
        }
        tail = task
        await task.value
    }

    // MARK: - Processing

    private func process(_ intent: LibraryIntent) async {
        switch intent.action {
        case let .requestMedia(entryID):
            guard now().timeIntervalSince(intent.createdAt) <= Self.maximumIntentAge else {
                mediaLog.notice("Ignored a media request for \(entryID.rawValue, privacy: .public) older than seven days")
                return
            }
            await serve(entryID, requester: intent.deviceID)
        case let .mediaCached(entryID, revisionID, deviceID):
            await acknowledge(entryID: entryID, revisionID: revisionID, deviceID: deviceID)
        default:
            return
        }
    }

    private func serve(_ entryID: ItemID, requester: String) async {
        do {
            guard let ready = try await source.readyAudio(for: entryID) else {
                try await publishNotReady(entryID, why: "no ready revision")
                return
            }
            guard ready.byteCount <= Self.maximumByteCount else {
                try await publishNotReady(entryID, why: "audio exceeds the size limit")
                return
            }
            guard Self.fileSize(ready.fileURL) == ready.byteCount else {
                try await publishNotReady(entryID, why: "the audio file is missing or changed")
                return
            }
            let key = AssetKey(entryID: entryID.rawValue, revisionID: ready.revisionID.rawValue)
            if published[entryID.rawValue] == key.revisionID, var existing = records[key] {
                existing.requesters.insert(requester)
                existing.acked.remove(requester)
                existing.touchedAt = now()
                records[key] = existing
                try persist()
                mediaLog.notice("Audio for \(entryID.rawValue, privacy: .public) is already offered; added a requester")
                return
            }
            let offer = try LibraryMediaOffer(
                entryID: entryID, revisionID: ready.revisionID, contentHash: ready.contentHash,
                byteCount: ready.byteCount, mediaType: ready.mediaType, durationSeconds: ready.durationSeconds
            )
            mediaLog.notice("Uploading \(ready.byteCount, privacy: .public) bytes of audio for \(entryID.rawValue, privacy: .public)")
            let started = Date()
            try await transport.publishMedia(offer: offer, fileURL: ready.fileURL)
            mediaLog.notice("Uploaded audio for \(entryID.rawValue, privacy: .public) in \(Date().timeIntervalSince(started), format: .fixed(precision: 1), privacy: .public) s")
            var record = records[key] ?? AssetRecord(key: key, requesters: [], acked: [], touchedAt: now())
            record.requesters.insert(requester)
            record.acked.remove(requester)
            record.touchedAt = now()
            records[key] = record
            published[entryID.rawValue] = key.revisionID
            try persist()
            lastFailure = nil
        } catch {
            lastFailure = String(describing: error)
            mediaLog.error("Media request for \(entryID.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Tells followers there is nothing to fetch and drops any asset the books still hold for the entry.
    private func publishNotReady(_ entryID: ItemID, why: String) async throws {
        mediaLog.notice("Publishing notReady for \(entryID.rawValue, privacy: .public): \(why, privacy: .public)")
        try await transport.publishMedia(offer: .notReady(entryID: entryID), fileURL: URL(fileURLWithPath: "/dev/null"))
        published[entryID.rawValue] = nil
        records = records.filter { $0.key.entryID != entryID.rawValue }
        try persist()
    }

    private func acknowledge(entryID: ItemID, revisionID: RevisionID, deviceID: String) async {
        let key = AssetKey(entryID: entryID.rawValue, revisionID: revisionID.rawValue)
        guard var record = records[key] else {
            mediaLog.notice("Ack from \(deviceID, privacy: .public) for \(entryID.rawValue, privacy: .public) matches no held asset")
            return
        }
        record.acked.insert(deviceID)
        records[key] = record
        do { try persist() } catch { mediaLog.error("Could not save media accounting: \(String(describing: error), privacy: .public)") }
        await cleanup()
    }

    /// Removes every record that is complete or expired. A withdrawal that fails keeps its
    /// record so the next sweep retries it.
    private func cleanup() async {
        let cutoff = now().addingTimeInterval(-Self.timeToLive)
        for record in records.values.sorted(by: { $0.touchedAt < $1.touchedAt }) where record.isComplete || record.touchedAt <= cutoff {
            let key = record.key
            if published[key.entryID] == key.revisionID {
                do {
                    let entryID = try ItemID(rawValue: key.entryID)
                    mediaLog.notice("Withdrawing audio for \(key.entryID, privacy: .public): \(record.isComplete ? "all requesters cached it" : "seven days elapsed", privacy: .public)")
                    try await transport.removeMedia(entryID: entryID)
                } catch {
                    lastFailure = String(describing: error)
                    mediaLog.error("Could not withdraw audio for \(key.entryID, privacy: .public): \(String(describing: error), privacy: .public)")
                    continue
                }
                published[key.entryID] = nil
            }
            records[key] = nil
        }
        do { try persist() } catch { mediaLog.error("Could not save media accounting: \(String(describing: error), privacy: .public)") }
    }

    // MARK: - Persistence

    private func persist() throws {
        guard let accountingURL else { return }
        try FileManager.default.createDirectory(at: accountingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stored = Stored(records: records.values.sorted { ($0.key.entryID, $0.key.revisionID) < ($1.key.entryID, $1.key.revisionID) }, published: published)
        try JSONEncoder().encode(stored).write(to: accountingURL, options: .atomic)
    }

    private static func fileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }
}
