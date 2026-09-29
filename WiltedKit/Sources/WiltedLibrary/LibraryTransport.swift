import Foundation
import WiltedDomain

/// Identity of one synchronized record. Removal state lives on the entry record,
/// so an entry upsert and a removal change share a key.
public struct LibraryRecordKey: Hashable, Sendable, Codable, CustomStringConvertible {
    public enum Kind: String, Codable, Sendable { case source, entry, slot, listening }

    public let kind: Kind
    public let id: ItemID

    public init(kind: Kind, id: ItemID) {
        self.kind = kind
        self.id = id
    }

    public var description: String { "\(kind.rawValue):\(id.rawValue)" }
}

/// One record-level mutation of library state, written only by the Mac.
public enum LibraryChange: Codable, Sendable, Equatable {
    case source(LibrarySource)
    case entry(LibraryEntry)
    /// Removal-only transition of an existing entry (retire, dismiss, restore).
    case removal(entryID: ItemID, state: LibraryRemoval)
    case slot(QueueSlot)
    case slotRemoved(entryID: ItemID)
    case listening(ListeningRecord)

    public var key: LibraryRecordKey {
        switch self {
        case let .source(source): return .init(kind: .source, id: source.id)
        case let .entry(entry): return .init(kind: .entry, id: entry.id)
        case let .removal(entryID, _): return .init(kind: .entry, id: entryID)
        case let .slot(slot): return .init(kind: .slot, id: slot.entryID)
        case let .slotRemoved(entryID): return .init(kind: .slot, id: entryID)
        case let .listening(record): return .init(kind: .listening, id: record.itemID)
        }
    }
}

/// A change stamped with the server version that produced it. Versions increase
/// strictly per key, which is what makes re-applying a batch a no-op.
public struct VersionedLibraryChange: Codable, Sendable, Equatable {
    public let version: UInt64
    public let change: LibraryChange

    public init(version: UInt64, change: LibraryChange) {
        self.version = version
        self.change = change
    }
}

/// Opaque resume position. Owned by the store; a transport only interprets its own tokens.
public struct LibraryChangeToken: Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
}

/// A complete remote generation of changes. Nothing here is committed until the
/// store commits it and the transport is told through `commitFetchedState`.
public struct LibraryChangeBatch: Sendable, Equatable {
    public let generationID: String
    public let changes: [VersionedLibraryChange]
    public let token: LibraryChangeToken?

    public init(generationID: String, changes: [VersionedLibraryChange], token: LibraryChangeToken?) {
        self.generationID = generationID
        self.changes = changes
        self.token = token
    }
}

/// A local mutation waiting to be sent. `localSeq` identifies this exact mutation
/// so a late acknowledgement cannot retire a newer replacement for the same key.
public struct PendingLibraryChange: Sendable, Equatable {
    public let localSeq: UInt64
    public let change: LibraryChange
    /// Server version of the record when the change was queued; 0 for a new record.
    public let baseVersion: UInt64

    public var key: LibraryRecordKey { change.key }

    public init(localSeq: UInt64, change: LibraryChange, baseVersion: UInt64) {
        self.localSeq = localSeq
        self.change = change
        self.baseVersion = baseVersion
    }
}

public struct LibraryAcknowledgement: Sendable, Equatable {
    public let key: LibraryRecordKey
    public let version: UInt64

    public init(key: LibraryRecordKey, version: UInt64) {
        self.key = key
        self.version = version
    }
}

public enum LibraryFailureDisposition: String, Sendable, Equatable { case conflict, retryable, terminal }

public struct LibraryPushFailure: Sendable, Equatable {
    public let key: LibraryRecordKey
    public let disposition: LibraryFailureDisposition
    /// The server's current version of the record, present for conflicts.
    public let server: VersionedLibraryChange?

    public init(key: LibraryRecordKey, disposition: LibraryFailureDisposition, server: VersionedLibraryChange? = nil) {
        self.key = key
        self.disposition = disposition
        self.server = server
    }
}

/// A partial send outcome. Acknowledgements and failures are independent per key.
public struct LibraryPushResult: Sendable, Equatable {
    public let token: LibraryChangeToken?
    public let acknowledged: [LibraryAcknowledgement]
    public let failures: [LibraryPushFailure]

    public init(token: LibraryChangeToken? = nil, acknowledged: [LibraryAcknowledgement] = [], failures: [LibraryPushFailure] = []) {
        self.token = token
        self.acknowledged = acknowledged
        self.failures = failures
    }
}

/// Which of a device's own playback records is being published.
public enum PlaybackChannel: String, Sendable, Equatable { case nowPlaying, progress }

/// Every device's playback records as the server observed them.
public struct LibraryDeviceRecords: Sendable, Equatable {
    public let nowPlaying: [ObservedPlayback]
    public let progress: [ObservedPlayback]

    public init(nowPlaying: [ObservedPlayback] = [], progress: [ObservedPlayback] = []) {
        self.nowPlaying = nowPlaying
        self.progress = progress
    }
}

public enum LibraryTransportError: Error, Equatable, Sendable {
    /// The store changed between staging and commit; re-stage from the new state.
    case staleStagedBatch
    /// An account or session change invalidated in-flight work.
    case superseded
    /// Every pending change is held by an unresolved conflict; nothing was sent.
    case sendBlockedByConflicts(count: Int)
    /// Only the library writer may push state, and a device writes only its own playback records.
    case ownershipViolation(String)
    case transport(String)
}

/// Backend-neutral library transport. CloudKit and hosted backends conform; the in-memory
/// transport is the reference. Commit semantics equal `SyncTransport`: fetched and sent
/// tokens are provisional until the caller commits them, only after the store has durably
/// applied the result.
public protocol LibraryTransport: Sendable {
    /// Generation captured by in-flight work; adapters bump it when ownership changes so
    /// stale results cannot be committed.
    func operationGeneration() async -> UInt64
    func fetchChanges(since token: LibraryChangeToken?) async throws -> LibraryChangeBatch
    func push(changes: [PendingLibraryChange]) async throws -> LibraryPushResult
    /// Idempotent by `LibraryIntent.id`.
    func send(intent: LibraryIntent) async throws
    func listIntents() async throws -> [LibraryIntent]
    /// Publishes this device's own record; `record.deviceID` must be this device.
    func publish(_ record: DevicePlaybackPosition, as channel: PlaybackChannel) async throws
    func fetchDeviceRecords() async throws -> LibraryDeviceRecords
    func commitFetchedState(_ token: LibraryChangeToken?) async throws
    func commitSentState(_ token: LibraryChangeToken?) async throws
}

public extension LibraryTransport {
    func operationGeneration() async -> UInt64 { 0 }
    func commitFetchedState(_ token: LibraryChangeToken?) async throws {}
    func commitSentState(_ token: LibraryChangeToken?) async throws {}
}
