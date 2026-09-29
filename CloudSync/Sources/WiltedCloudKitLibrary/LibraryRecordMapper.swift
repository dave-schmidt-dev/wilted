import CloudKit
import Foundation
import WiltedCloudKit
import WiltedDomain
import WiltedLibrary

/// The seven CloudKit record types of the library zone.
public enum LibraryRecordType: String, CaseIterable, Sendable {
    case entry = "LibraryEntryRecord"
    case source = "LibrarySourceRecord"
    case slot = "QueueSlotRecord"
    case nowPlaying = "NowPlayingRecord"
    case progress = "ProgressRecord"
    case listening = "ListeningRecord"
    case intent = "IntentRecord"

    /// Record-name prefix. Names for device-written records embed the device id, so each
    /// record has exactly one writer and two devices can never collide on a name.
    var namePrefix: String {
        switch self {
        case .entry: "entry:"
        case .source: "source:"
        case .slot: "slot:"
        case .nowPlaying: "nowplaying:"
        case .progress: "progress:"
        case .listening: "listening:"
        case .intent: "intent:"
        }
    }
}

public enum LibraryRecordMapperError: Error, Equatable, Sendable {
    case invalidRecordName(String)
    case wrongZone(String)
    case missingPayload(String)
    case payloadTooLarge(Int)
    case malformedPayload(recordName: String, reason: String)
    /// The record name does not match the identity inside its payload (forged or corrupt).
    case identityMismatch(String)
    /// A removal-only change needs the server's current entry to apply the state to.
    case missingBaseEntry(String)
}

/// One decoded fetched record. `skipped` covers record types this client does not know;
/// they are ignored (and logged by the transport) so a newer writer never breaks an older reader.
public enum LibraryDecodedRecord: Sendable, Equatable {
    case library(LibraryChange)
    case playback(PlaybackChannel, DevicePlaybackPosition)
    case intent(LibraryIntent)
    case skipped(recordType: String)
}

/// A CloudKit save or delete, kept out of `Sendable` land because `CKRecord` is a reference type.
public enum LibraryRecordOperation {
    case save(CKRecord)
    case delete(CKRecord.ID)
}

/// Pure translation between library values and `CKRecord`s.
///
/// Every record carries its whole value as JSON in one `Bytes` field (`payload`); there are
/// no asset fields, so a record can never pull audio or artwork through CloudKit.
public struct LibraryRecordMapper: Sendable {
    public static let zoneName = "WiltedLibraryZone"
    public static let payloadField = "payload"
    /// CloudKit limits a record to about 1 MB; payloads are far smaller by contract.
    public static let maximumPayloadBytes = 256 * 1024

    public let zoneID: CKRecordZone.ID

    public init(ownerName: String = CKCurrentUserDefaultName) {
        zoneID = CKRecordZone.ID(zoneName: Self.zoneName, ownerName: ownerName)
    }

    // MARK: Names

    public func recordID(for key: LibraryRecordKey) -> CKRecord.ID {
        let type: LibraryRecordType
        switch key.kind {
        case .entry: type = .entry
        case .source: type = .source
        case .slot: type = .slot
        case .listening: type = .listening
        }
        return CKRecord.ID(recordName: type.namePrefix + key.id.rawValue, zoneID: zoneID)
    }

    /// The library key a record name denotes, or nil for device-written names and unknown prefixes.
    public func key(forRecordName name: String) -> LibraryRecordKey? {
        let table: [(LibraryRecordType, LibraryRecordKey.Kind)] =
            [(.entry, .entry), (.source, .source), (.slot, .slot), (.listening, .listening)]
        for (type, kind) in table where name.hasPrefix(type.namePrefix) {
            guard let id = try? ItemID(rawValue: String(name.dropFirst(type.namePrefix.count))) else { return nil }
            return LibraryRecordKey(kind: kind, id: id)
        }
        return nil
    }

    public func recordID(playback record: DevicePlaybackPosition, channel: PlaybackChannel) throws -> CKRecord.ID {
        switch channel {
        case .nowPlaying: try id(.nowPlaying, [record.deviceID])
        case .progress: try id(.progress, [record.deviceID, record.entryID.rawValue])
        }
    }

    public func recordID(intent: LibraryIntent) throws -> CKRecord.ID {
        try id(.intent, [intent.deviceID, intent.id])
    }

    private func id(_ type: LibraryRecordType, _ parts: [String]) throws -> CKRecord.ID {
        let name = type.namePrefix + parts.joined(separator: ":")
        guard !parts.contains(where: \.isEmpty), name.utf8.count <= 255,
              name.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7F }) else {
            throw LibraryRecordMapperError.invalidRecordName(name)
        }
        return CKRecord.ID(recordName: name, zoneID: zoneID)
    }

    // MARK: Encoding

    /// Builds the operation for a pending change. `existing` is the last known server record
    /// (carrying its change tag) and is copied, never mutated; it is required for a removal-only change.
    public func operation(for change: LibraryChange, existing: CKRecord?) throws -> LibraryRecordOperation {
        switch change {
        case let .source(value): return .save(try save(.source, recordID(for: change.key), value, existing))
        case let .entry(value): return .save(try save(.entry, recordID(for: change.key), value, existing))
        case let .slot(value): return .save(try save(.slot, recordID(for: change.key), value, existing))
        case let .listening(value): return .save(try save(.listening, recordID(for: change.key), value, existing))
        case let .slotRemoved(entryID):
            return .delete(recordID(for: LibraryRecordKey(kind: .slot, id: entryID)))
        case let .removal(entryID, state):
            guard let existing, case let .library(.entry(entry))? = try? decode(existing) else {
                throw LibraryRecordMapperError.missingBaseEntry(entryID.rawValue)
            }
            return .save(try save(.entry, recordID(for: change.key), entry.applyingRemoval(state), existing))
        }
    }

    public func record(playback: DevicePlaybackPosition, channel: PlaybackChannel, existing: CKRecord? = nil) throws -> CKRecord {
        try save(channel == .nowPlaying ? .nowPlaying : .progress, recordID(playback: playback, channel: channel), playback, existing)
    }

    public func record(intent: LibraryIntent, existing: CKRecord? = nil) throws -> CKRecord {
        try save(.intent, recordID(intent: intent), intent, existing)
    }

    private func save<Value: Encodable>(_ type: LibraryRecordType, _ id: CKRecord.ID, _ value: Value, _ existing: CKRecord?) throws -> CKRecord {
        let data = try Self.encoder.encode(value)
        guard data.count <= Self.maximumPayloadBytes else { throw LibraryRecordMapperError.payloadTooLarge(data.count) }
        let record: CKRecord
        if let existing {
            guard existing.recordType == type.rawValue, existing.recordID == id,
                  let copy = existing.copy() as? CKRecord else {
                throw LibraryRecordMapperError.identityMismatch(id.recordName)
            }
            record = copy
        } else {
            record = CKRecord(recordType: type.rawValue, recordID: id)
        }
        record[Self.payloadField] = data as CKRecordValue
        return record
    }

    // MARK: Decoding

    /// Decodes one fetched record. A foreign record type is `.skipped`, not an error; a known
    /// type with a bad payload, wrong zone, or a name that disagrees with its payload throws.
    public func decode(_ record: CKRecord) throws -> LibraryDecodedRecord {
        guard let type = LibraryRecordType(rawValue: record.recordType) else {
            return .skipped(recordType: record.recordType)
        }
        let name = record.recordID.recordName
        guard record.recordID.zoneID == zoneID else { throw LibraryRecordMapperError.wrongZone(record.recordID.zoneID.zoneName) }
        guard let data = record[Self.payloadField] as? Data else { throw LibraryRecordMapperError.missingPayload(name) }
        do {
            switch type {
            case .entry:
                let value = try Self.decoder.decode(LibraryEntry.self, from: data)
                try expect(name, recordID(for: LibraryChange.entry(value).key))
                return .library(.entry(value))
            case .source:
                let value = try Self.decoder.decode(LibrarySource.self, from: data)
                try expect(name, recordID(for: LibraryChange.source(value).key))
                return .library(.source(value))
            case .slot:
                let value = try Self.decoder.decode(QueueSlot.self, from: data)
                try expect(name, recordID(for: LibraryChange.slot(value).key))
                return .library(.slot(value))
            case .listening:
                let value = try Self.decoder.decode(ListeningRecord.self, from: data)
                try expect(name, recordID(for: LibraryChange.listening(value).key))
                return .library(.listening(value))
            case .nowPlaying, .progress:
                let value = try Self.decoder.decode(DevicePlaybackPosition.self, from: data)
                let channel: PlaybackChannel = type == .nowPlaying ? .nowPlaying : .progress
                try expect(name, recordID(playback: value, channel: channel))
                return .playback(channel, value)
            case .intent:
                let value = try Self.decoder.decode(LibraryIntent.self, from: data)
                try expect(name, recordID(intent: value))
                return .intent(value)
            }
        } catch let error as LibraryRecordMapperError {
            throw error
        } catch {
            throw LibraryRecordMapperError.malformedPayload(recordName: name, reason: String(describing: error))
        }
    }

    /// The change a fetched deletion represents, or nil when it is not a library deletion
    /// (only queue slots are ever deleted; every other record changes state instead).
    public func deletion(recordID: CKRecord.ID, recordType: String) -> LibraryChange? {
        guard recordType == LibraryRecordType.slot.rawValue, recordID.zoneID == zoneID,
              let key = key(forRecordName: recordID.recordName), key.kind == .slot else { return nil }
        return .slotRemoved(entryID: key.id)
    }

    private func expect(_ name: String, _ id: CKRecord.ID) throws {
        guard name == id.recordName else { throw LibraryRecordMapperError.identityMismatch(name) }
    }

    /// Monotonic per-record version: the server modification time in microseconds. It also
    /// keeps increasing across a zone reset, which a counter stored in the record would not.
    public static func version(of record: CKRecord) -> UInt64? {
        record.modificationDate.map { UInt64(max(0, $0.timeIntervalSince1970) * 1_000_000) }
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static var decoder: JSONDecoder { JSONDecoder() }
}

// MARK: - Transport support

/// Records queued for the sync engine. The engine asks for each record by id when it
/// builds a batch, so the transport parks them here for the duration of one send.
public final class CloudKitLibraryOutbox: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [CKRecord.ID: CKRecord] = [:]

    public init() {}

    /// The `recordProvider` handed to `LiveCloudKitEngineDriver`.
    public func record(for id: CKRecord.ID) -> CKRecord? { lock.withLock { records[id] } }
    func set(_ new: [CKRecord]) { lock.withLock { records = Dictionary(new.map { ($0.recordID, $0) }, uniquingKeysWith: { $1 }) } }
    func clear() { lock.withLock { records = [:] } }
}

/// Records gathered from one engine fetch, already decoded.
struct LibraryFetchAccumulator {
    var library: [LibraryRecordKey: VersionedLibraryChange] = [:]
    var playback: [String: (channel: PlaybackChannel, observed: ObservedPlayback)] = [:]
    var intents: [String: LibraryIntent] = [:]
    var state: Data?
}
struct LibrarySendAccumulator {
    var saved: [String: UInt64] = [:]
    var deleted: Set<String> = []
    var failed: [String: (disposition: LibraryFailureDisposition, server: CKRecord?)] = [:]
    var zoneMissing = false
    var state: Data?
}

extension CloudKitLibraryTransport {
    static func isServerReset(_ error: Error) -> Bool {
        guard let code = (error as? CKError)?.code else { return false }
        return code == .zoneNotFound || code == .changeTokenExpired || code == .userDeletedZone
    }

    static func token(_ state: Data) -> LibraryChangeToken { LibraryChangeToken(rawValue: state.base64EncodedString()) }

    static func stateData(_ token: LibraryChangeToken?) throws -> Data? {
        guard let token else { return nil }
        guard let data = Data(base64Encoded: token.rawValue), !data.isEmpty else { throw CloudKitSyncError.stateCorrupt }
        return data
    }
}

#if WILTED_CLOUDKIT_LIVE
public extension CloudKitLibraryTransport {
    /// Builds live engines against `containerIdentifier`'s private database, each bootstrapping
    /// `WiltedLibraryZone` (not the legacy `WiltedZone` the shared factory defaults to).
    nonisolated static func makeLiveFactory(containerIdentifier: String, outbox: CloudKitLibraryOutbox,
                                            mapper: LibraryRecordMapper = LibraryRecordMapper()) -> CloudKitEngineDriverFactory {
        let database = CKContainer(identifier: containerIdentifier).privateCloudDatabase
        return { stateData in
            let serialization: CKSyncEngine.State.Serialization?
            if let stateData {
                guard let decoded = try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: stateData) else {
                    throw CloudKitSyncError.stateCorrupt
                }
                serialization = decoded
            } else { serialization = nil }
            return LiveCloudKitEngineDriver(
                database: database, stateSerialization: serialization,
                zoneBootstrap: LiveCloudKitZoneBootstrap(database: database, zoneID: mapper.zoneID),
                recordProvider: { outbox.record(for: $0) })
        }
    }
}
#endif
