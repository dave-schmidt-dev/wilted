import Foundation
import OSLog
import WiltedDomain
import WiltedLibrary

#if canImport(WiltedProducer)
import WiltedProducer
#endif

private let mediaLog = Logger(subsystem: "com.zerodelta.wilted", category: "MacMedia")

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
///
/// Every `requestMedia` is held in a `WiltedMacMediaUploadQueue`, saved to `queueURL` (in memory
/// when nil, for tests). An upload that fails transiently stays queued and retries until
/// `maximumIntentAge`; this service makes one attempt at a time and the queue owns the waits.
actor WiltedMacMediaService {
    static let timeToLive: TimeInterval = 7 * 24 * 60 * 60
    /// A queued request older than this is failed rather than retried.
    static let maximumIntentAge: TimeInterval = 7 * 24 * 60 * 60
    /// Mirrors the transport limit so an oversize file is answered `notReady` up front.
    static let maximumByteCount: Int64 = 250 * 1024 * 1024
    /// The wait before the first retry of an upload that failed; later retries wait longer.
    static let defaultUploadRetryDelay: Duration = .seconds(5)

    /// Told each stage of a media request after `received`, so the requesting device can show it.
    typealias RequestReporter = @Sendable (LibraryIntent, LibraryMediaRequestStatus.Stage, String?) async -> Void
    /// Writes the accounting bytes to its file and reports whether the folder sync is certain.
    typealias AccountingWriter = @Sendable (Data, URL) throws -> DurableFile.ReplacementResult

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

    /// Lets the queue reach its service without keeping it alive, as the queue is built inside `init`.
    private final class ServiceLink: @unchecked Sendable {
        weak var service: WiltedMacMediaService?
    }

    let source: any WiltedMacReadyAudioSource
    let transport: any LibraryTransport
    private let accountingURL: URL?
    private let accountingWrite: AccountingWriter
    private let now: @Sendable () -> Date
    var records: [AssetKey: AssetRecord] = [:]
    var published: [String: String] = [:]
    /// What the transport holds per entry, seeded from it on the first reconcile.
    var offered: [String: LibraryMediaOffer] = [:]
    var offersSeeded = false
    /// The `available` offer each prepared queued entry should show, from the last reconcile.
    var availableOffers: [String: LibraryMediaOffer] = [:]
    var publishedTranscripts: [String: String] = [:]
    private var tail: Task<Void, Never>?
    private var sweepQueued = false
    private let reportRequest: RequestReporter?
    var lastFailure: String?
    /// The queue every media request passes through.
    let uploadQueue: WiltedMacMediaUploadQueue

    /// - Parameters:
    ///   - uploadRetryDelay: the wait before the first retry of a failed upload.
    ///   - sleep: how that wait passes. Tests replace it so a retry costs no real time.
    ///   - reportRequest: told `sending`, `answered` or `failed` for each media request it serves.
    ///   - accountingWrite: writes the accounting bytes; tests replace it to fail the folder sync.
    ///   - queueURL: where the upload queue is saved; nil keeps it in memory only (tests).
    ///   - queueWrite: writes the queue bytes; tests replace it to fail or watch a save.
    init(
        source: any WiltedMacReadyAudioSource, transport: any LibraryTransport, accountingURL: URL?,
        now: @escaping @Sendable () -> Date = { Date() },
        uploadRetryDelay: Duration = WiltedMacMediaService.defaultUploadRetryDelay,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        reportRequest: RequestReporter? = nil,
        accountingWrite: @escaping AccountingWriter = { try DurableFile.replace($0, to: $1) },
        queueURL: URL? = nil,
        queueWrite: @escaping WiltedMacMediaUploadQueue.Writer = { try DurableFile.replace($0, to: $1) }
    ) {
        self.reportRequest = reportRequest
        self.source = source
        self.transport = transport
        self.accountingURL = accountingURL
        self.accountingWrite = accountingWrite
        self.now = now
        if let accountingURL, let data = try? Data(contentsOf: accountingURL) {
            if let stored = try? JSONDecoder().decode(Stored.self, from: data) {
                records = Dictionary(stored.records.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
                published = stored.published
                publishedTranscripts = stored.transcripts ?? [:]
            } else {
                // Unreadable accounting is set aside, not overwritten, and the service starts empty.
                let aside = accountingURL.appendingPathExtension("corrupt")
                try? FileManager.default.removeItem(at: aside)
                try? FileManager.default.moveItem(at: accountingURL, to: aside)
                mediaLog.error("Media accounting was unreadable and was set aside")
            }
        }
        let link = ServiceLink()
        uploadQueue = WiltedMacMediaUploadQueue(
            fileURL: queueURL, now: now, uploadRetryDelay: uploadRetryDelay, sleep: sleep,
            reportRequest: reportRequest, write: queueWrite
        ) { intent, isRetry in
            guard let service = link.service else { throw CancellationError() }
            try await service.attemptQueued(intent, isRetry: isRetry)
        }
        link.service = self
    }

    // MARK: - Entry points (serialized: one upload or withdrawal at a time)

    /// Applies one media intent and waits for it; other intents are ignored.
    func handle(_ intent: LibraryIntent) async {
        await enqueue(intent).value
    }

    /// Queues one media intent behind the work already queued and returns at once, so a sync round
    /// never waits on an upload and a request sent during one is still read in the next round.
    @discardableResult
    func enqueue(_ intent: LibraryIntent) async -> Task<Void, Never> {
        if case .requestMedia = intent.action {
            do { return try await uploadQueue.admit(intent) } catch {
                mediaLog.error("Media request was not queued and is not served: \(String(describing: error), privacy: .public)")
                return Task {}
            }
        }
        return chained { await self.process(intent) }
    }

    /// Queues a sweep unless one is already waiting, and returns at once.
    func scheduleSweep() {
        guard !sweepQueued else { return }
        sweepQueued = true
        chained {
            await self.beginSweep()
            await self.cleanup()
        }
    }

    /// Waits for every queued request and sweep like `drain()`, but ends any wait for iCloud
    /// throttling at once so shutdown does not sit behind it. A request that was waiting stays
    /// queued and is served on the next launch.
    func drainEndingThrottleWaits() async {
        await uploadQueue.drainEndingThrottleWaits()
        await tail?.value
    }

    /// Waits for every queued request and sweep.
    func drain() async {
        await uploadQueue.drain()
        await tail?.value
    }

    private func beginSweep() { sweepQueued = false }

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
        await chained(work).value
    }

    @discardableResult
    private func chained<T: Sendable>(_ work: @escaping @Sendable () async -> T) -> Task<T, Never> {
        let previous = tail
        let task = Task<T, Never> {
            await previous?.value
            return await work()
        }
        tail = Task { _ = await task.value }
        return task
    }

    // MARK: - Processing

    private func process(_ intent: LibraryIntent) async {
        switch intent.action {
        case let .mediaCached(entryID, revisionID, deviceID):
            await acknowledge(entryID: entryID, revisionID: revisionID, deviceID: deviceID)
        default:
            return
        }
    }

    /// One attempt to serve a request the durable queue holds, run in turn with the other work on
    /// this service. Throws what went wrong, for the queue to retry or fail; reports nothing itself
    /// beyond the stages of a working attempt.
    func attemptQueued(_ intent: LibraryIntent, isRetry: Bool) async throws {
        guard case let .requestMedia(entryID) = intent.action else { return }
        let outcome = await serialized { () async -> Result<Void, any Error> in
            do { return .success(try await self.serve(entryID, for: intent, isRetry: isRetry)) } catch { return .failure(error) }
        }
        try outcome.get()
    }

    /// The plain words a device is shown when a request cannot be answered.
    static let failedDetail = "The Mac could not send the audio. Try again."

    /// Answers one request. Throws, after logging, when it could not; the caller decides whether
    /// that is a retry or a failure to report. A retry does not repeat the `sending` stage.
    private func serve(_ entryID: ItemID, for intent: LibraryIntent, isRetry: Bool = false) async throws {
        let requester = intent.deviceID
        do {
            guard let ready = try await source.readyAudio(for: entryID) else {
                try await publishNotReady(entryID, why: "no ready revision")
                await reportRequest?(intent, .answered, "This episode is not prepared on the Mac yet.")
                return
            }
            guard ready.byteCount <= Self.maximumByteCount else {
                try await publishNotReady(entryID, why: "audio exceeds the size limit")
                await reportRequest?(intent, .answered, "This episode's audio is too large to send.")
                return
            }
            guard Self.fileSize(ready.fileURL) == ready.byteCount else {
                try await publishNotReady(entryID, why: "the audio file is missing or changed")
                await reportRequest?(intent, .answered, "The Mac's audio file for this episode is missing.")
                return
            }
            let offer = try LibraryMediaOffer(
                entryID: entryID, revisionID: ready.revisionID, contentHash: ready.contentHash,
                byteCount: ready.byteCount, mediaType: ready.mediaType, durationSeconds: ready.durationSeconds,
                preparation: ready.preparation
            )
            let key = AssetKey(entryID: entryID.rawValue, revisionID: ready.revisionID.rawValue)
            // Unseeded offers only cost a fresh upload, so a failed read falls through to one.
            try? await seedOffers()
            if published[entryID.rawValue] == key.revisionID, offered[entryID.rawValue] == offer,
               var existing = records[key] {
                existing.requesters.insert(requester)
                existing.acked.remove(requester)
                existing.touchedAt = now()
                records[key] = existing
                try persist()
                await publishTranscript(for: entryID, revisionID: ready.revisionID)
                mediaLog.notice("Audio for \(entryID.rawValue, privacy: .public) is already offered; added a requester")
                await reportRequest?(intent, .answered, nil)
                return
            }
            if !isRetry { await reportRequest?(intent, .sending, nil) }
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
            await reportRequest?(intent, .answered, nil)
        } catch {
            // No offer is published. The typed cause stays in this Mac's log, because the link
            // record the device reads is synced to other devices.
            let cause = Self.typedCause(error)
            lastFailure = cause
            mediaLog.error("Media request for \(entryID.rawValue, privacy: .public) failed: \(cause, privacy: .public)")
            throw error
        }
    }

    /// The error's type and value, e.g. `CloudKitSyncError.cloudKit(code: 4, message: "…")`. A
    /// Foundation error arrives bridged as `NSError`, so it is named by domain and code instead,
    /// e.g. `NSURLErrorDomain(-1005)`.
    static func typedCause(_ error: Error) -> String {
        if error is URLError || type(of: error) is NSError.Type {
            let bridged = error as NSError
            return "\(bridged.domain)(\(bridged.code))"
        }
        return "\(type(of: error)).\(String(describing: error))"
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
    func dropBooks(for entry: String) {
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
                        try await transport.publishMedia(offer: .notReady(entryID: entryID), fileURL: URL(fileURLWithPath: "/dev/null"))
                        offered[key.entryID] = .notReady(entryID: entryID)
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

    // MARK: - Persistence

    func persist() throws {
        guard let accountingURL else { return }
        try FileManager.default.createDirectory(at: accountingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stored = Stored(records: records.values.sorted { ($0.key.entryID, $0.key.revisionID) < ($1.key.entryID, $1.key.revisionID) }, published: published, transcripts: publishedTranscripts)
        let data = try JSONEncoder().encode(stored)
        let result = try accountingWrite(data, accountingURL)
        if case let .replacedDirectorySyncUncertain(failure) = result {
            mediaLog.warning("Media accounting landed but its folder sync is uncertain: \(failure.description, privacy: .public)")
        }
    }

    static func fileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }
}
