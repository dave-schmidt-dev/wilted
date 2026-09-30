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
    /// Ready audio for every entry on the Larder (queued and not retired), from one read.
    func preparedQueuedAudio() async throws -> [ItemID: WiltedMacReadyAudio]
    /// The compact transcript the Mac already holds for exactly this revision, or nil.
    func transcript(for entryID: ItemID, revisionID: RevisionID) async throws -> LibraryTranscript?
    /// The transcripts held for exactly these revisions, from one read; entries without one are absent.
    func transcripts(for revisions: [ItemID: RevisionID]) async throws -> [ItemID: LibraryTranscript]
}

extension WiltedMacReadyAudioSource {
    func transcript(for entryID: ItemID, revisionID: RevisionID) async throws -> LibraryTranscript? { nil }

    func transcripts(for revisions: [ItemID: RevisionID]) async throws -> [ItemID: LibraryTranscript] {
        var found: [ItemID: LibraryTranscript] = [:]
        for (entryID, revisionID) in revisions {
            if let value = try await transcript(for: entryID, revisionID: revisionID) { found[entryID] = value }
        }
        return found
    }
}

#if canImport(WiltedProducer)
/// `WiltedMacReadyAudioSource` over the existing one-read library snapshot.
struct WiltedMacLocalReadyAudioSource: WiltedMacReadyAudioSource {
    let store: LocalLibraryStore

    func readyAudio(for entryID: ItemID) async throws -> WiltedMacReadyAudio? {
        try await store.podcastLibrarySnapshot().readyRevisions[entryID].map(Self.audio)
    }

    func preparedQueuedAudio() async throws -> [ItemID: WiltedMacReadyAudio] {
        let snapshot = try await store.podcastLibrarySnapshot()
        let queue = try await store.podcastQueueState().episodeIDs
        var prepared: [ItemID: WiltedMacReadyAudio] = [:]
        for id in queue where snapshot.retiredAtByEpisode[id] == nil {
            if let stored = snapshot.readyRevisions[id] { prepared[id] = Self.audio(stored) }
        }
        return prepared
    }

    private static func audio(_ stored: StoredAudioRevision) -> WiltedMacReadyAudio {
        let revision = stored.revision
        return WiltedMacReadyAudio(
            revisionID: revision.revisionID, contentHash: revision.contentHash, byteCount: revision.byteCount,
            mediaType: revision.mediaType, durationSeconds: revision.durationSeconds, fileURL: stored.mediaURL
        )
    }

    func transcript(for entryID: ItemID, revisionID: RevisionID) async throws -> LibraryTranscript? {
        let stored = try await store.podcastLibrarySnapshot().transcripts["\(entryID.rawValue)|\(revisionID.rawValue)"]
        return stored.flatMap { LibraryTranscript.capped(entryID: entryID, from: $0) }
    }

    func transcripts(for revisions: [ItemID: RevisionID]) async throws -> [ItemID: LibraryTranscript] {
        let stored = try await store.podcastLibrarySnapshot().transcripts
        var found: [ItemID: LibraryTranscript] = [:]
        for (entryID, revisionID) in revisions {
            if let value = stored["\(entryID.rawValue)|\(revisionID.rawValue)"],
               let capped = LibraryTranscript.capped(entryID: entryID, from: value) { found[entryID] = capped }
        }
        return found
    }
}
#endif

/// Serves `requestMedia`, keeps an `available` offer up for every prepared Larder entry, and
/// retires assets, on the Mac only.
///
/// `reconcileAvailable` publishes `available` offers (metadata only, no upload) for the prepared
/// queued entries and withdraws offers for entries that left the Larder; a request then uploads
/// the audio and turns the offer `ready`, and once every requester has cached it the asset is
/// withdrawn and the offer returns to `available` while the entry is still prepared and queued.
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
        /// Entry id to the revision whose transcript is on the transport. Absent in older files.
        var transcripts: [String: String]?
    }

    private let source: any WiltedMacReadyAudioSource
    private let transport: any LibraryTransport
    private let accountingURL: URL?
    private let now: @Sendable () -> Date
    private var records: [AssetKey: AssetRecord] = [:]
    private var published: [String: String] = [:]
    /// What the transport holds per entry, seeded from it on the first reconcile.
    private var offered: [String: LibraryMediaOffer] = [:]
    private var offersSeeded = false
    /// The `available` offer each prepared queued entry should show, from the last reconcile.
    private var availableOffers: [String: LibraryMediaOffer] = [:]
    private var publishedTranscripts: [String: String] = [:]
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
            publishedTranscripts = stored.transcripts ?? [:]
        }
    }

    // MARK: - Entry points (serialized: one upload or withdrawal at a time)

    /// Applies one media intent; other intents are ignored.
    func handle(_ intent: LibraryIntent) async {
        await serialized { await self.process(intent) }
    }

    /// Brings the offers in line with the prepared Larder: publishes `available` for prepared
    /// queued entries that have no offer at their revision, and withdraws offers for entries that
    /// left the Larder. Uploads nothing. False when something could not be published, so the
    /// caller retries.
    @discardableResult
    func reconcileAvailable() async -> Bool {
        await serialized { await self.reconcile() }
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

    private func serialized<T: Sendable>(_ work: @escaping @Sendable () async -> T) async -> T {
        let previous = tail
        let task = Task<T, Never> {
            await previous?.value
            return await work()
        }
        tail = Task { _ = await task.value }
        return await task.value
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
                await publishTranscript(for: entryID, revisionID: ready.revisionID)
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
            offered[entryID.rawValue] = offer
            try persist()
            await publishTranscript(for: entryID, revisionID: ready.revisionID)
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
        offered[entryID.rawValue] = .notReady(entryID: entryID)
        dropBooks(for: entryID.rawValue)
        await withdrawTranscript(for: entryID.rawValue)
        try persist()
    }

    /// Forgets the asset accounting for an entry whose audio is no longer on the transport.
    private func dropBooks(for entry: String) {
        published[entry] = nil
        records = records.filter { $0.key.entryID != entry }
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
                    if let available = availableOffers[key.entryID], available.revisionID?.rawValue == key.revisionID {
                        // Still prepared and queued: drop the audio, keep the offer as `available` and
                        // the transcript with it, so a phone that cached the audio before transcripts
                        // existed (or lost its copy) can still fetch it.
                        try await transport.publishMedia(offer: available, fileURL: URL(fileURLWithPath: "/dev/null"))
                        offered[key.entryID] = available
                    } else {
                        // Transcript first: if it fails the audio stays held, so the next sweep retries both.
                        try await removeTranscriptIfHeld(for: key.entryID)
                        try await transport.removeMedia(entryID: entryID)
                        offered[key.entryID] = nil
                    }
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

    // MARK: - Available offers

    private func reconcile() async -> Bool {
        let prepared: [ItemID: WiltedMacReadyAudio]
        do {
            prepared = try await source.preparedQueuedAudio()
            if !offersSeeded {
                for offer in try await transport.mediaOffers() { offered[offer.entryID.rawValue] = offer }
                offersSeeded = true
            }
        } catch {
            lastFailure = String(describing: error)
            mediaLog.error("Could not read the prepared Larder to publish offers: \(String(describing: error), privacy: .public)")
            return false
        }
        var desired: [String: LibraryMediaOffer] = [:]
        for (entryID, audio) in prepared where audio.byteCount <= Self.maximumByteCount && Self.fileSize(audio.fileURL) == audio.byteCount {
            desired[entryID.rawValue] = try? LibraryMediaOffer(
                entryID: entryID, revisionID: audio.revisionID, contentHash: "", byteCount: audio.byteCount,
                mediaType: audio.mediaType, durationSeconds: audio.durationSeconds, state: .available
            )
        }
        availableOffers = desired
        var succeeded = true
        // A `notReady` offer answers a request rather than describing the Larder, so it is left alone.
        for (raw, offer) in offered.sorted(by: { $0.key < $1.key }) where desired[raw] == nil && offer.state != .notReady {
            do {
                await withdrawTranscript(for: raw)
                try await transport.removeMedia(entryID: offer.entryID)
                dropBooks(for: raw)
                offered[raw] = nil
                mediaLog.notice("Withdrew the offer for \(raw, privacy: .public): it left the Larder or is no longer prepared")
            } catch {
                succeeded = false
                mediaLog.error("Could not withdraw the offer for \(raw, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        for (raw, want) in desired.sorted(by: { $0.key < $1.key }) {
            if let current = offered[raw], current.revisionID == want.revisionID {
                if current.state == .available { continue }
                if current.state == .ready, published[raw] == want.revisionID?.rawValue { continue }
            }
            do {
                try await transport.publishMedia(offer: want, fileURL: URL(fileURLWithPath: "/dev/null"))
                await withdrawTranscript(for: raw)
                dropBooks(for: raw)
                offered[raw] = want
            } catch {
                succeeded = false
                mediaLog.error("Could not publish the available offer for \(raw, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        await publishMissingTranscripts(for: desired)
        do { try persist() } catch { mediaLog.error("Could not save media accounting: \(String(describing: error), privacy: .public)") }
        if succeeded { lastFailure = nil }
        return succeeded
    }

    /// Publishes the transcript of every prepared Larder entry that has one and is not yet published
    /// at its revision, without a request. A phone that downloaded audio before transcripts existed
    /// never asks again, so this is the only way it gets one. Entries without a transcript are left
    /// alone; a failure is logged and retried by the next reconcile.
    private func publishMissingTranscripts(for desired: [String: LibraryMediaOffer]) async {
        var pending: [ItemID: RevisionID] = [:]
        for (raw, offer) in desired {
            guard let revisionID = offer.revisionID, publishedTranscripts[raw] != revisionID.rawValue else { continue }
            pending[offer.entryID] = revisionID
        }
        guard !pending.isEmpty else { return }
        let found: [ItemID: LibraryTranscript]
        do { found = try await source.transcripts(for: pending) } catch {
            mediaLog.error("Could not read transcripts to publish: \(String(describing: error), privacy: .public)")
            return
        }
        for (entryID, transcript) in found.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            guard transcript.revisionID == pending[entryID] else { continue }
            do {
                try await transport.publishTranscript(transcript)
                publishedTranscripts[entryID.rawValue] = transcript.revisionID.rawValue
                mediaLog.notice("Published the transcript for \(entryID.rawValue, privacy: .public) without a request")
            } catch {
                mediaLog.error("Transcript for \(entryID.rawValue, privacy: .public) was not published: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: - Transcript (published with the audio, withdrawn with it)

    /// Publishes the Mac's transcript for `revisionID` once. A missing transcript, or a failure,
    /// never affects the audio: the transcript is retried by the next request for the entry.
    private func publishTranscript(for entryID: ItemID, revisionID: RevisionID) async {
        if publishedTranscripts[entryID.rawValue] == revisionID.rawValue { return }
        do {
            guard let transcript = try await source.transcript(for: entryID, revisionID: revisionID) else {
                // A transcript left over from an older revision would never be asked for; drop it.
                await withdrawTranscript(for: entryID.rawValue)
                return
            }
            try await transport.publishTranscript(transcript)
            publishedTranscripts[entryID.rawValue] = revisionID.rawValue
            try persist()
            mediaLog.notice("Published the transcript for \(entryID.rawValue, privacy: .public)")
        } catch {
            mediaLog.error("Transcript for \(entryID.rawValue, privacy: .public) was not published: \(String(describing: error), privacy: .public)")
        }
    }

    /// Withdraws a held transcript, logging rather than failing; the audio flow must not depend on it.
    private func withdrawTranscript(for entryID: String) async {
        do { try await removeTranscriptIfHeld(for: entryID) } catch {
            mediaLog.error("Could not withdraw the transcript for \(entryID, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    private func removeTranscriptIfHeld(for entryID: String) async throws {
        guard publishedTranscripts[entryID] != nil else { return }
        try await transport.removeTranscript(entryID: try ItemID(rawValue: entryID))
        publishedTranscripts[entryID] = nil
        try persist()
    }

    // MARK: - Persistence

    private func persist() throws {
        guard let accountingURL else { return }
        try FileManager.default.createDirectory(at: accountingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stored = Stored(records: records.values.sorted { ($0.key.entryID, $0.key.revisionID) < ($1.key.entryID, $1.key.revisionID) }, published: published, transcripts: publishedTranscripts)
        try JSONEncoder().encode(stored).write(to: accountingURL, options: .atomic)
    }

    private static func fileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }
}
