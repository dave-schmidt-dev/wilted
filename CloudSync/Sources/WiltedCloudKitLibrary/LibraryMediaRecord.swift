import CloudKit
import Foundation
import WiltedCloudKit
import WiltedDomain
import WiltedLibrary

/// The entries that currently have a media offer. Only the library writer writes it, which is
/// what lets a phone find offers by name without scanning the zone.
public struct LibraryOfferIndex: Codable, Sendable, Equatable {
    public let entryIDs: [ItemID]
    public init(entryIDs: [ItemID]) { self.entryIDs = entryIDs }
}

/// The ids of the intents one device has sent. Only that device writes it.
public struct LibraryIntentIndex: Codable, Sendable, Equatable {
    public let deviceID: String
    public let intentIDs: [String]
    public init(deviceID: String, intentIDs: [String]) {
        self.deviceID = deviceID
        self.intentIDs = intentIDs
    }
}

/// The `WiltedAudio` record: one `CKAsset` plus the offer fields, in `WiltedMediaZone`.
///
/// The Mac is the only writer. Engines and scans are scoped to the library zone, so this
/// record's bytes only ever move through `saveRecordRaw` and `fetchAssetRecordRaw`.
public enum LibraryMediaRecord {
    public static let zoneName = "WiltedMediaZone"
    public static let recordType = "WiltedAudio"
    public static let namePrefix = "audio:"
    public static let assetField = "asset"
    /// The largest asset the spike measured (250 MB); larger offers are rejected.
    public static let maximumByteCount: Int64 = 250 * 1024 * 1024

    public static func recordID(entryID: ItemID, zoneID: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: namePrefix + entryID.rawValue, zoneID: zoneID)
    }

    /// Builds the record for a ready offer; `assetURL` must be a file the caller no longer needs.
    public static func record(offer: LibraryMediaOffer, assetURL: URL, zoneID: CKRecordZone.ID) throws -> CKRecord {
        guard offer.state == .ready, let revisionID = offer.revisionID else {
            throw LibraryTransportError.transport("only a ready offer has audio to upload")
        }
        guard offer.byteCount <= maximumByteCount else {
            throw LibraryTransportError.transport("audio for \(offer.entryID.rawValue) exceeds the \(maximumByteCount) byte limit")
        }
        let record = CKRecord(recordType: recordType, recordID: recordID(entryID: offer.entryID, zoneID: zoneID))
        record["entryID"] = offer.entryID.rawValue as CKRecordValue
        record["revisionID"] = revisionID.rawValue as CKRecordValue
        record["contentHash"] = offer.contentHash as CKRecordValue
        record["byteCount"] = NSNumber(value: offer.byteCount)
        record["mediaType"] = offer.mediaType as CKRecordValue
        if let duration = offer.durationSeconds { record["durationSeconds"] = NSNumber(value: duration) }
        record[assetField] = CKAsset(fileURL: assetURL)
        return record
    }

    /// The offer a fetched audio record describes, validated like any offer.
    public static func offer(from record: CKRecord) throws -> LibraryMediaOffer {
        guard record.recordType == recordType,
              let entry = record["entryID"] as? String, let revision = record["revisionID"] as? String,
              let hash = record["contentHash"] as? String, let bytes = record["byteCount"] as? NSNumber,
              let mediaType = record["mediaType"] as? String
        else { throw LibraryRecordMapperError.missingPayload(record.recordID.recordName) }
        return try LibraryMediaOffer(
            entryID: ItemID(rawValue: entry), revisionID: RevisionID(rawValue: revision), contentHash: hash,
            byteCount: bytes.int64Value, mediaType: mediaType,
            durationSeconds: (record["durationSeconds"] as? NSNumber)?.doubleValue)
    }
}

/// Device ids and entry ids seen in fetched records: the names a targeted fetch asks for.
struct LibraryPeerDirectory {
    var devices: Set<String> = []
    var entries: Set<ItemID> = []

    mutating func note(device: String? = nil, entry: ItemID? = nil) {
        if let device, !device.isEmpty { devices.insert(device) }
        if let entry { entries.insert(entry) }
    }
}

/// Elapsed time since a transfer last reported progress.
private final class MediaProgressClock: @unchecked Sendable {
    private let lock = NSLock()
    private var last = DispatchTime.now().uptimeNanoseconds
    func touch() { lock.withLock { last = DispatchTime.now().uptimeNanoseconds } }
    var secondsSinceProgress: Double {
        Double(DispatchTime.now().uptimeNanoseconds - lock.withLock { last }) / 1_000_000_000
    }
}

// MARK: - Targeted reads (no engine, no zone scan)

extension CloudKitLibraryTransport {
    /// Teaches the transport device and entry ids to ask for by name. Fetched records add to the
    /// same set, so this is only needed to seed a cold start.
    public func track(devices: [String] = [], entries: [ItemID] = []) {
        devices.forEach { peers.note(device: $0) }
        entries.forEach { peers.note(entry: $0) }
    }

    /// One whole-zone scan that learns every device and entry id and every intent already
    /// present. Call it once at startup or on demand; polling never does.
    @discardableResult
    public func discoverPeers() async throws -> Int {
        _ = try await scan()
        return peers.devices.count
    }

    /// The named records that exist, fetched outside the transport's serial gate.
    func fetchPresent(_ ids: [CKRecord.ID]) async throws -> [CKRecord] {
        guard !quarantined else { throw CloudKitSyncError.quarantined }
        let unique = Array(Set(ids))
        var found: [CKRecord] = []
        do {
            for start in stride(from: 0, to: unique.count, by: 100) {
                found += try await driver.fetchRecordsIfPresent(Array(unique[start..<min(start + 100, unique.count)]), desiredKeys: nil)
            }
        } catch { throw failure(error) }
        for record in found { serverRecords[record.recordID.recordName] = record }
        return found
    }

    public func listIntents() async throws -> [LibraryIntent] {
        let devices = peers.devices.union([deviceID]).sorted()
        var wanted: [(name: String, deviceID: String, id: String)] = []
        for record in try await fetchPresent(devices.compactMap { try? mapper.recordID(intentIndexFor: $0) }) {
            guard case let .intentIndex(index)? = try? mapper.decode(record) else { continue }
            peers.note(device: index.deviceID)
            for id in index.intentIDs {
                guard let name = try? mapper.recordID(intentID: id, deviceID: index.deviceID).recordName else { continue }
                wanted.append((name, index.deviceID, id))
            }
        }
        let missing = wanted.filter { intentCache[$0.name] == nil }
            .compactMap { try? mapper.recordID(intentID: $0.id, deviceID: $0.deviceID) }
        for record in try await fetchPresent(missing) {
            // An intent is immutable, so a cached one never needs refreshing.
            if case let .intent(value)? = try? mapper.decode(record) { intentCache[record.recordID.recordName] = value }
        }
        return wanted.compactMap { intentCache[$0.name] }.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    public func fetchDeviceRecords() async throws -> LibraryDeviceRecords {
        var observed: [String: (channel: PlaybackChannel, observed: ObservedPlayback)] = [:]
        var asked = Set<String>()
        let devices = peers.devices.union([deviceID]).sorted()
        func names(nowPlaying: Bool) -> [CKRecord.ID] {
            let entries = peers.entries.sorted { $0.rawValue < $1.rawValue }
            var ids: [CKRecord.ID] = []
            for device in devices {
                if nowPlaying, let id = try? mapper.recordID(nowPlayingFor: device) { ids.append(id) }
                ids += entries.compactMap { try? mapper.recordID(progressFor: device, entryID: $0) }
            }
            return ids.filter { asked.insert($0.recordName).inserted }
        }
        var ids = names(nowPlaying: true)
        // The second round covers entries first named by a now-playing record from this call.
        for _ in 0..<2 where !ids.isEmpty {
            for record in try await fetchPresent(ids) {
                guard case let .playback(channel, value)? = try? mapper.decode(record) else { continue }
                peers.note(device: value.deviceID, entry: value.entryID)
                observed[record.recordID.recordName] = (channel, ObservedPlayback(
                    record: value, serverModifiedAt: record.modificationDate ?? .distantPast))
            }
            ids = names(nowPlaying: false)
        }
        func ordered(_ channel: PlaybackChannel) -> [ObservedPlayback] {
            observed.values.filter { $0.channel == channel }.map(\.observed)
                .sorted { ($0.record.deviceID, $0.record.entryID.rawValue) < ($1.record.deviceID, $1.record.entryID.rawValue) }
        }
        return LibraryDeviceRecords(nowPlaying: ordered(.nowPlaying), progress: ordered(.progress))
    }

    public func mediaOffers() async throws -> [LibraryMediaOffer] {
        let indexRecords = try await fetchPresent([mapper.offerIndexRecordID])
        guard case let .offerIndex(index)? = indexRecords.compactMap({ try? mapper.decode($0) }).first else { return [] }
        index.entryIDs.forEach { peers.note(entry: $0) }
        let records = try await fetchPresent(index.entryIDs.compactMap { try? mapper.recordID(offerFor: $0) })
        return records.compactMap { record -> LibraryMediaOffer? in
            guard case let .offer(offer)? = try? mapper.decode(record) else { return nil }
            return offer
        }.sorted { $0.entryID.rawValue < $1.entryID.rawValue }
    }

    /// Adds this device's intent id to its index record, loading the stored index first.
    func recordOwnIntent(_ intentID: String) async throws {
        let indexID = try mapper.recordID(intentIndexFor: deviceID)
        if ownIntentIDs == nil {
            var loaded = Set<String>()
            let stored = try await fetchPresent([indexID])
            if case let .intentIndex(index)? = stored.compactMap({ try? mapper.decode($0) }).first { loaded = Set(index.intentIDs) }
            ownIntentIDs = loaded
        }
        ownIntentIDs?.insert(intentID)
        let mine = ownIntentIDs ?? [intentID]
        let device = deviceID
        try await write(name: indexID.recordName, conflictIsSuccess: false) { base in
            var merged = mine
            if let base, case let .intentIndex(server)? = try? self.mapper.decode(base) { merged.formUnion(server.intentIDs) }
            return try self.mapper.record(intentIndex: LibraryIntentIndex(deviceID: device, intentIDs: merged.sorted()), existing: base)
        }
    }
}

// MARK: - Media transfer

extension CloudKitLibraryTransport {
    public func publishMedia(offer: LibraryMediaOffer, fileURL: URL) async throws {
        try requireMediaWriter()
        let audioID = LibraryMediaRecord.recordID(entryID: offer.entryID, zoneID: mapper.mediaZoneID)
        if offer.state == .ready {
            guard offer.byteCount <= LibraryMediaRecord.maximumByteCount else {
                throw LibraryTransportError.transport("audio for \(offer.entryID.rawValue) is \(offer.byteCount) bytes; the limit is \(LibraryMediaRecord.maximumByteCount)")
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value
            guard size == offer.byteCount else {
                throw LibraryTransportError.transport("the file for \(offer.entryID.rawValue) does not match the offered byte count")
            }
            try await upload(offer, from: fileURL)
        } else {
            do { try await driver.deleteRecordsRaw([audioID]) } catch { throw failure(error) }
        }
        // The offer is saved only after its asset is durable, so it never points at nothing.
        try await write(name: try mapper.recordID(offerFor: offer.entryID).recordName, conflictIsSuccess: false) {
            try self.mapper.record(offer: offer, existing: $0)
        }
        try await updateOfferIndex(adding: offer.entryID, removing: nil)
        peers.note(entry: offer.entryID)
    }

    public func fetchMedia(_ offer: LibraryMediaOffer, progress: @escaping MediaProgressHandler) async throws -> URL {
        guard !quarantined else { throw CloudKitSyncError.quarantined }
        guard offer.state == .ready, offer.revisionID != nil else {
            throw LibraryTransportError.transport("no ready audio is offered for \(offer.entryID.rawValue)")
        }
        guard offer.byteCount <= LibraryMediaRecord.maximumByteCount else {
            throw LibraryTransportError.transport("the offer for \(offer.entryID.rawValue) exceeds the size limit")
        }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("wilted-media-\(UUID().uuidString).download")
        let id = LibraryMediaRecord.recordID(entryID: offer.entryID, zoneID: mapper.mediaZoneID)
        let target = driver, total = offer.byteCount
        log.notice("Downloading \(total, privacy: .public) bytes of audio for \(offer.entryID.rawValue, privacy: .public)")
        do {
            // The record is parsed inside the task, so only a `Sendable` offer crosses the watchdog.
            let delivered = try await withMediaWatchdog { touch in
                let record = try await target.fetchAssetRecordRaw(id, assetField: LibraryMediaRecord.assetField, to: destination) { fraction in
                    touch()
                    progress(Int64(min(max(fraction, 0), 1) * Double(total)))
                }
                return try LibraryMediaRecord.offer(from: record)
            }
            guard delivered.revisionID == offer.revisionID, delivered.contentHash == offer.contentHash,
                  delivered.byteCount == offer.byteCount else {
                throw LibraryTransportError.transport("the audio for \(offer.entryID.rawValue) changed since it was offered; refresh offers")
            }
            log.notice("Downloaded audio for \(offer.entryID.rawValue, privacy: .public)")
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw failure(error)
        }
    }

    public func removeMedia(entryID: ItemID) async throws {
        try requireMediaWriter()
        // Offer first, so no offer ever points at a missing asset.
        try await deleteFromLibraryZone(try mapper.recordID(offerFor: entryID))
        try await updateOfferIndex(adding: nil, removing: entryID)
        do { try await driver.deleteRecordsRaw([LibraryMediaRecord.recordID(entryID: entryID, zoneID: mapper.mediaZoneID)]) }
        catch { throw failure(error) }
        log.notice("Removed audio for \(entryID.rawValue, privacy: .public)")
    }

    private func requireMediaWriter() throws {
        guard isLibraryWriter else { throw LibraryTransportError.ownershipViolation("\(deviceID) may not publish media") }
        guard !quarantined else { throw CloudKitSyncError.quarantined }
    }

    private func upload(_ offer: LibraryMediaOffer, from fileURL: URL) async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("wilted-media-upload-\(UUID().uuidString)", isDirectory: true)
        let copy = scratch.appendingPathComponent("audio.bin")
        defer { try? FileManager.default.removeItem(at: scratch) }
        do {
            // The transport uploads its own copy, so the caller's file may change or vanish meanwhile.
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            try await Task.detached { try FileManager.default.copyItem(at: fileURL, to: copy) }.value
            let record = try LibraryMediaRecord.record(offer: offer, assetURL: copy, zoneID: mapper.mediaZoneID)
            let target = driver
            log.notice("Uploading \(offer.byteCount, privacy: .public) bytes of audio for \(offer.entryID.rawValue, privacy: .public)")
            try await target.ensureZone(mapper.mediaZoneID)
            try await withMediaWatchdog { touch in try await target.saveRecordRaw(record) { _ in touch() } }
            log.notice("Uploaded audio for \(offer.entryID.rawValue, privacy: .public)")
        } catch { throw failure(error) }
    }

    /// Runs `body` and abandons it when it reports no progress for `mediaWatchdogInterval`.
    private func withMediaWatchdog<T: Sendable>(
        _ body: @escaping @Sendable (@escaping @Sendable () -> Void) async throws -> T
    ) async throws -> T {
        let clock = MediaProgressClock()
        let interval = mediaWatchdogInterval
        return try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await body { clock.touch() } }
            group.addTask {
                let tick = UInt64(min(max(interval / 10, 0.005), 5) * 1_000_000_000)
                while true {
                    try await Task.sleep(nanoseconds: tick)
                    if clock.secondsSinceProgress > interval {
                        throw LibraryTransportError.transport("media transfer stalled: no progress for \(Int(interval)) s")
                    }
                }
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let value = first else {
                throw LibraryTransportError.transport("media transfer ended without a result")
            }
            return value
        }
    }

    private func deleteFromLibraryZone(_ id: CKRecord.ID) async throws {
        await acquire()
        defer { release() }
        guard !quarantined else { throw CloudKitSyncError.quarantined }
        do {
            try await driver.ensureZone()
            let acc = try await runSend(saves: [], deletes: [id])
            if acc.zoneMissing || acc.deleted.contains(id.recordName) { return }
            if acc.failed[id.recordName] != nil { throw LibraryTransportError.transport("delete of \(id.recordName) failed") }
        } catch { throw failure(error) }
    }

    private func updateOfferIndex(adding: ItemID?, removing: ItemID?) async throws {
        try await write(name: mapper.offerIndexRecordID.recordName, conflictIsSuccess: false) { base in
            var entries: Set<ItemID> = []
            if let base, case let .offerIndex(server)? = try? self.mapper.decode(base) { entries = Set(server.entryIDs) }
            if let adding { entries.insert(adding) }
            if let removing { entries.remove(removing) }
            return try self.mapper.record(offerIndex: LibraryOfferIndex(entryIDs: entries.sorted { $0.rawValue < $1.rawValue }), existing: base)
        }
    }
}
