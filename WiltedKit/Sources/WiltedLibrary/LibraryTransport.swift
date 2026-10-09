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
    public let provenance: LibraryFetchProvenance?
    public let observedPublication: LibraryPublication?

    public init(generationID: String, changes: [VersionedLibraryChange], token: LibraryChangeToken?,
                provenance: LibraryFetchProvenance? = nil, observedPublication: LibraryPublication? = nil) {
        self.generationID = generationID
        self.changes = changes
        self.token = token
        self.provenance = provenance
        self.observedPublication = observedPublication
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

/// What one inbound poll reads. A transport fetches everything asked for in as few requests as
/// it can (one, when the names are known), because a sync round is one batch, not one request per read.
public struct LibraryPollOptions: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    /// The intents every known device has sent (the Mac).
    public static let intents = LibraryPollOptions(rawValue: 1 << 0)
    /// Every device's now-playing and progress records.
    public static let deviceRecords = LibraryPollOptions(rawValue: 1 << 1)
    /// The Mac's media offers.
    public static let offers = LibraryPollOptions(rawValue: 1 << 2)
    /// The Mac's answers to this device's intents (the phone).
    public static let outcomes = LibraryPollOptions(rawValue: 1 << 3)
}

/// The parts of an inbound poll that were asked for; the others stay nil or empty.
public struct LibraryPollResult: Sendable, Equatable {
    public var intents: [LibraryIntent]
    public var records: LibraryDeviceRecords?
    public var offers: [LibraryMediaOffer]?
    public var outcomes: [IntentOutcome]?

    public init(
        intents: [LibraryIntent] = [], records: LibraryDeviceRecords? = nil,
        offers: [LibraryMediaOffer]? = nil, outcomes: [IntentOutcome]? = nil
    ) {
        self.intents = intents
        self.records = records
        self.offers = offers
        self.outcomes = outcomes
    }
}

/// Cumulative bytes received so far by a media download.
public typealias MediaProgressHandler = @Sendable (Int64) -> Void

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
    /// Current-launch observed owner, never just the constructor's saved owner.
    func verifiedOwnerToken() async -> String?
    func fetchChanges(since token: LibraryChangeToken?) async throws -> LibraryChangeBatch
    func push(changes: [PendingLibraryChange]) async throws -> LibraryPushResult
    /// Idempotent by `LibraryIntent.id`.
    func send(intent: LibraryIntent) async throws
    func listIntents() async throws -> [LibraryIntent]
    /// Mac only: records the answer to one intent. Immutable and idempotent by `intentID`.
    func publishIntentOutcome(_ outcome: IntentOutcome) async throws
    /// Every outcome the Mac has published, oldest first.
    func intentOutcomes() async throws -> [IntentOutcome]
    /// Publishes this device's own record; `record.deviceID` must be this device.
    func publish(_ record: DevicePlaybackPosition, as channel: PlaybackChannel) async throws
    func fetchDeviceRecords() async throws -> LibraryDeviceRecords
    /// Publishes several of this device's own records as one write, so the now-playing and
    /// progress records of one moment cost one operation.
    func publish(_ records: [(record: DevicePlaybackPosition, channel: PlaybackChannel)]) async throws
    /// The inbound reads of one sync round, as one batch. See `LibraryPollOptions`.
    func poll(_ options: LibraryPollOptions) async throws -> LibraryPollResult
    /// Mac only: offers `fileURL` as the audio for `offer`. The transport takes its own copy.
    func publishMedia(offer: LibraryMediaOffer, fileURL: URL) async throws
    /// Current offers, one per entry, learned without staging any audio.
    func mediaOffers() async throws -> [LibraryMediaOffer]
    /// Downloads the audio for a ready `offer` and returns a file the caller owns and must
    /// verify (`MediaFetcher`); `progress` receives the cumulative bytes received.
    func fetchMedia(_ offer: LibraryMediaOffer, progress: @escaping MediaProgressHandler) async throws -> URL
    /// Mac only: withdraws the audio and offer for `entryID`.
    func removeMedia(entryID: ItemID) async throws
    /// Mac only: publishes the lifetime statistics. One record, replaced by each publish.
    func publishStats(_ stats: LibraryStats) async throws
    /// The Mac's last published statistics, or nil before it has published any. Read by name.
    func readStats() async throws -> LibraryStats?
    /// Writer only. Acknowledges the dedicated publication record before returning.
    func publishPublication(_ publication: LibraryPublication) async throws
    /// Observed author evidence only; not proof of the reader's displayed snapshot.
    func readPublication() async throws -> LibraryPublication?
    /// Mac only: publishes the transcript for one prepared revision. One per entry; a newer
    /// revision replaces the older. Kept apart from the library state, so no state fetch carries it.
    func publishTranscript(_ transcript: LibraryTranscript) async throws
    /// The published transcript for exactly this revision, or nil when none is published or the
    /// published one belongs to a different revision. Read by name; never triggers a zone scan.
    func transcript(entryID: ItemID, revisionID: RevisionID) async throws -> LibraryTranscript?
    /// Mac only: withdraws the transcript for `entryID`, alongside its audio.
    func removeTranscript(entryID: ItemID) async throws
    func commitFetchedState(_ token: LibraryChangeToken?) async throws
    func commitSentState(_ token: LibraryChangeToken?) async throws
}

public extension LibraryTransport {
    func operationGeneration() async -> UInt64 { 0 }
    func verifiedOwnerToken() async -> String? { nil }
    func publish(_ records: [(record: DevicePlaybackPosition, channel: PlaybackChannel)]) async throws {
        for item in records { try await publish(item.record, as: item.channel) }
    }
    func poll(_ options: LibraryPollOptions) async throws -> LibraryPollResult {
        var result = LibraryPollResult()
        if options.contains(.intents) { result.intents = try await listIntents() }
        if options.contains(.deviceRecords) { result.records = try await fetchDeviceRecords() }
        if options.contains(.offers) { result.offers = try await mediaOffers() }
        if options.contains(.outcomes) { result.outcomes = try await intentOutcomes() }
        return result
    }
    func publishMedia(offer: LibraryMediaOffer, fileURL: URL) async throws {
        throw LibraryTransportError.transport("media transfer is not supported by this transport")
    }
    func publishIntentOutcome(_ outcome: IntentOutcome) async throws {
        throw LibraryTransportError.transport("intent outcomes are not supported by this transport")
    }
    func intentOutcomes() async throws -> [IntentOutcome] { [] }
    func mediaOffers() async throws -> [LibraryMediaOffer] { [] }
    func fetchMedia(_ offer: LibraryMediaOffer, progress: @escaping MediaProgressHandler) async throws -> URL {
        throw LibraryTransportError.transport("media transfer is not supported by this transport")
    }
    func removeMedia(entryID: ItemID) async throws {}
    func publishStats(_ stats: LibraryStats) async throws {
        throw LibraryTransportError.transport("statistics are not supported by this transport")
    }
    func readStats() async throws -> LibraryStats? { nil }
    func publishPublication(_ publication: LibraryPublication) async throws {
        throw LibraryTransportError.transport("library publication is not supported by this transport")
    }
    func readPublication() async throws -> LibraryPublication? { nil }
    func publishTranscript(_ transcript: LibraryTranscript) async throws {
        throw LibraryTransportError.transport("transcripts are not supported by this transport")
    }
    func transcript(entryID: ItemID, revisionID: RevisionID) async throws -> LibraryTranscript? { nil }
    func removeTranscript(entryID: ItemID) async throws {}
    func commitFetchedState(_ token: LibraryChangeToken?) async throws {}
    func commitSentState(_ token: LibraryChangeToken?) async throws {}
}
