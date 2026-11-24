import Foundation
import WiltedDomain

/// Lifecycle of one story after its narrated audio is ready for playback.
/// Request preparation has its own state; this ledger owns player admission.
public enum ListenNextPlaybackPhase: String, Codable, Sendable {
    case pending
    case sent
    case preparing
    case ready
    case selected
    case starting
    case playing
    case completed
    case failed
    case cancelled
}

/// The queue that should continue after a story finishes.
public struct ListenNextContinuation: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case macReadyLarder
        case macPlaylist
        case phoneForwardSequence
    }

    public let kind: Kind
    public let anchorID: ItemID
    public let entryIDs: [ItemID]
    public let nextIndex: Int
    public let playlistID: String?
    /// Whether natural completion may admit the saved suffix without a new Play command.
    public let allowsAutomaticContinuation: Bool?

    public init(kind: Kind, anchorID: ItemID, entryIDs: [ItemID], nextIndex: Int = 0,
                playlistID: String? = nil, allowsAutomaticContinuation: Bool? = true) {
        self.kind = kind
        self.anchorID = anchorID
        self.entryIDs = entryIDs
        self.nextIndex = min(max(0, nextIndex), entryIDs.count)
        self.playlistID = playlistID
        self.allowsAutomaticContinuation = allowsAutomaticContinuation
    }

    public var remainingEntryIDs: ArraySlice<ItemID> { entryIDs.dropFirst(nextIndex) }
    public var shouldAutomaticallyContinue: Bool { allowsAutomaticContinuation ?? true }
}

/// The exact delivered audio value bound to a request in the local playback ledger.
public struct ListenNextAudioOfferIdentity: Codable, Equatable, Sendable {
    public let audioRevisionID: String
    public let contentHash: String
    public let byteCount: Int64
    public let mediaType: String
    public let durationSeconds: Double

    public init(audioRevisionID: String, contentHash: String, byteCount: Int64,
                mediaType: String, durationSeconds: Double) {
        self.audioRevisionID = audioRevisionID
        self.contentHash = contentHash
        self.byteCount = byteCount
        self.mediaType = mediaType
        self.durationSeconds = durationSeconds
    }
}

/// A device-local, account-bound handoff ledger for narrated story playback.
/// Callers encode and durably save a mutated value before invoking player start.
public struct ListenNextPlaybackLedger: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        public let requestID: String
        public let storyID: ItemID
        public let requesterDeviceID: String
        public let ownerToken: String
        public let operationGeneration: UInt64
        public let anchorID: ItemID?
        public let createdAt: Date
        public var phase: ListenNextPlaybackPhase
        public var holdEpoch: UInt64
        public var boundaryID: String?
        public var continuation: ListenNextContinuation?
        public var positionSeconds: Double
        public var mediaFilePath: String?
        public var audioOfferIdentity: ListenNextAudioOfferIdentity?

        public var id: String { requestID }
    }

    public let schemaVersion: Int
    public let requesterDeviceID: String
    public let ownerToken: String
    public let operationGeneration: UInt64
    public private(set) var entries: [Entry]
    public private(set) var latestBoundaryID: String?
    public private(set) var latestContinuation: ListenNextContinuation?
    public private(set) var latestHoldEpoch: UInt64?

    public init(requesterDeviceID: String, ownerToken: String, operationGeneration: UInt64,
                entries: [Entry] = [], latestBoundaryID: String? = nil,
                latestContinuation: ListenNextContinuation? = nil, latestHoldEpoch: UInt64? = nil) {
        self.schemaVersion = 1
        self.requesterDeviceID = requesterDeviceID
        self.ownerToken = ownerToken
        self.operationGeneration = operationGeneration
        self.entries = entries.filter {
            $0.requesterDeviceID == requesterDeviceID && $0.ownerToken == ownerToken
                && $0.operationGeneration == operationGeneration
        }
        self.latestBoundaryID = latestBoundaryID
        self.latestContinuation = latestContinuation
        self.latestHoldEpoch = latestHoldEpoch
    }

    /// Loads only the exact account, device, and generation that own this queue.
    /// Old data stays inert after account recovery rather than being replayed.
    public static func decode(_ data: Data?, requesterDeviceID: String, ownerToken: String,
                              operationGeneration: UInt64) -> Self {
        guard let data, let decoded = try? JSONDecoder().decode(Self.self, from: data),
              decoded.schemaVersion == 1, decoded.requesterDeviceID == requesterDeviceID,
              decoded.ownerToken == ownerToken, decoded.operationGeneration == operationGeneration else {
            return Self(requesterDeviceID: requesterDeviceID, ownerToken: ownerToken,
                        operationGeneration: operationGeneration)
        }
        return decoded
    }

    /// Adds a request once, retaining its FIFO order when readiness is updated.
    public mutating func record(
        requestID: String, storyID: ItemID, requesterDeviceID: String, ownerToken: String,
        operationGeneration: UInt64, anchorID: ItemID?, createdAt: Date, holdEpoch: UInt64,
        phase: ListenNextPlaybackPhase = .ready
    ) {
        guard requesterDeviceID == self.requesterDeviceID, ownerToken == self.ownerToken,
              operationGeneration == self.operationGeneration, !requestID.isEmpty else { return }
        if let index = entries.firstIndex(where: { $0.requestID == requestID }) {
            guard entries[index].phase == .pending || entries[index].phase == .sent
                || entries[index].phase == .preparing || entries[index].phase == .ready else { return }
            entries[index].phase = phase
            return
        }
        entries.append(Entry(
            requestID: requestID, storyID: storyID, requesterDeviceID: requesterDeviceID,
            ownerToken: ownerToken, operationGeneration: operationGeneration, anchorID: anchorID,
            createdAt: createdAt, phase: phase, holdEpoch: holdEpoch, boundaryID: nil,
            continuation: nil, positionSeconds: 0, mediaFilePath: nil, audioOfferIdentity: nil
        ))
        entries.sort(by: Self.isEarlier)
    }

    /// Chooses the oldest nonterminal request only when it is ready. A pending
    /// older request holds later audio in FIFO order. Failed and cancelled
    /// requests do not block the queue. Persist the returned selection before
    /// starting its audio.
    @discardableResult
    public mutating func selectAtNaturalBoundary(
        boundaryID: String, continuation: ListenNextContinuation, currentHoldEpoch: UInt64
    ) -> Entry? {
        guard let index = entries.firstIndex(where: { $0.phase == .selected || $0.phase == .starting || $0.phase == .playing }) else {
            while let first = entries.firstIndex(where: { $0.phase != .completed && $0.phase != .failed && $0.phase != .cancelled }) {
                let candidate = entries[first]
                guard candidate.holdEpoch == currentHoldEpoch, candidate.phase == .ready else { return nil }
                entries[first].phase = .selected
                entries[first].boundaryID = boundaryID
                entries[first].continuation = continuation
                entries[first].positionSeconds = 0
                return entries[first]
            }
            return nil
        }
        let active = entries[index]
        guard active.holdEpoch == currentHoldEpoch else { return nil }
        guard active.boundaryID == boundaryID, active.continuation == continuation else { return active }
        return active
    }

    /// A new explicit Play or Listen next action releases requests held by an
    /// earlier stop. The caller persists this change with its user command.
    public mutating func releaseHold(onExplicitStartAt holdEpoch: UInt64) {
        for index in entries.indices where Self.isActive(entries[index].phase) {
            entries[index].holdEpoch = holdEpoch
        }
    }

    /// Refreshes remote preparation progress while preserving a player-owned
    /// selection and its saved continuation.
    public mutating func updateRequestPhase(requestID: String, phase: ListenNextPlaybackPhase) {
        guard let index = entries.firstIndex(where: { $0.requestID == requestID }) else { return }
        switch entries[index].phase {
        case .selected, .starting, .playing, .completed:
            return
        default:
            entries[index].phase = phase
        }
    }

    public mutating func setReadyMedia(
        requestID: String, fileURL: URL, audioOfferIdentity: ListenNextAudioOfferIdentity? = nil
    ) {
        guard let index = entries.firstIndex(where: { $0.requestID == requestID }),
              entries[index].phase == .pending || entries[index].phase == .sent
                || entries[index].phase == .preparing || entries[index].phase == .ready else { return }
        entries[index].phase = .ready
        entries[index].mediaFilePath = fileURL.standardizedFileURL.path
        entries[index].audioOfferIdentity = audioOfferIdentity
    }

    /// Returns the saved continuation only after the request completion is
    /// durable. Callers then admit its next entry with their normal eligibility
    /// checks and retain the saved suffix when one entry has since disappeared.
    public func continuationAfterCompletion(requestID: String) -> ListenNextContinuation? {
        entries.first(where: { $0.requestID == requestID && $0.phase == .completed })?.continuation
    }

    /// Finds a completion interrupted between the local ledger write and the
    /// remote status write. The caller must reconcile `.playing` remotely
    /// before admitting the saved continuation.
    public func completedEntryForRecovery(
        requestID: String, remotePhase: ListenNextPlaybackPhase
    ) -> Entry? {
        guard remotePhase == .playing || remotePhase == .completed,
              let entry = entries.first(where: { $0.requestID == requestID }),
              entry.phase == .completed, entry.continuation != nil else { return nil }
        return entry
    }

    /// Marks the durable pre-start fence. A crash from this point is recovered
    /// by checking whether the player already owns this request's audio.
    public mutating func markStarting(requestID: String) {
        guard let index = entries.firstIndex(where: { $0.requestID == requestID }),
              entries[index].phase == .selected || entries[index].phase == .starting else { return }
        entries[index].phase = .starting
    }

    /// Releases a pre-start reservation after a newer hold supersedes it.
    /// The ready media and FIFO timestamp remain available for a later boundary.
    public mutating func returnAbandonedStartToReady(requestID: String) {
        guard let index = entries.firstIndex(where: { $0.requestID == requestID }),
              entries[index].phase == .selected || entries[index].phase == .starting else { return }
        entries[index].phase = .ready
        entries[index].boundaryID = nil
        entries[index].continuation = nil
    }

    public mutating func markPlaying(requestID: String, positionSeconds: Double = 0) {
        guard let index = entries.firstIndex(where: { $0.requestID == requestID }),
              entries[index].phase == .starting || entries[index].phase == .playing,
              positionSeconds.isFinite, positionSeconds >= 0 else { return }
        entries[index].phase = .playing
        entries[index].positionSeconds = positionSeconds
    }

    public mutating func savePosition(requestID: String, positionSeconds: Double) {
        guard let index = entries.firstIndex(where: { $0.requestID == requestID }),
              entries[index].phase == .playing, positionSeconds.isFinite, positionSeconds >= 0 else { return }
        entries[index].positionSeconds = positionSeconds
    }

    /// Commits story completion before the saved continuation is admitted.
    public mutating func markCompleted(requestID: String) {
        guard let index = entries.firstIndex(where: { $0.requestID == requestID }),
              entries[index].phase == .playing || entries[index].phase == .starting else { return }
        entries[index].phase = .completed
    }

    public mutating func updateContinuation(requestID: String, continuation: ListenNextContinuation) {
        guard let index = entries.firstIndex(where: { $0.requestID == requestID }),
              entries[index].phase == .playing || entries[index].phase == .starting
                || entries[index].phase == .completed else { return }
        entries[index].continuation = continuation
    }

    public mutating func markFailed(requestID: String) {
        updateTerminalPhase(requestID: requestID, phase: .failed)
    }

    public mutating func markCancelled(requestID: String) {
        updateTerminalPhase(requestID: requestID, phase: .cancelled)
    }

    /// Finds a selection after relaunch. A `starting` entry is safe to retry
    /// only after the caller confirms the player is not already on this story.
    public var activeEntry: Entry? {
        entries.first { $0.phase == .selected || $0.phase == .starting || $0.phase == .playing }
    }

    public func encoded() throws -> Data { try JSONEncoder().encode(self) }

    /// Saves the normal queue suffix at every natural boundary, including when
    /// no story is ready. A later audio-ready event can then start only if that
    /// boundary is still the player's ended state.
    public mutating func recordNaturalBoundary(
        boundaryID: String, continuation: ListenNextContinuation, holdEpoch: UInt64
    ) {
        latestBoundaryID = boundaryID
        latestContinuation = continuation
        latestHoldEpoch = holdEpoch
    }

    public var hasUnchangedNaturalBoundary: Bool {
        latestBoundaryID != nil && latestContinuation != nil && latestHoldEpoch != nil
    }

    private mutating func updateTerminalPhase(requestID: String, phase: ListenNextPlaybackPhase) {
        guard let index = entries.firstIndex(where: { $0.requestID == requestID }),
              entries[index].phase != .completed else { return }
        entries[index].phase = phase
        entries[index].mediaFilePath = nil
        entries[index].audioOfferIdentity = nil
    }

    private static func isEarlier(_ lhs: Entry, _ rhs: Entry) -> Bool {
        lhs.createdAt == rhs.createdAt ? lhs.requestID < rhs.requestID : lhs.createdAt < rhs.createdAt
    }

    private static func isActive(_ phase: ListenNextPlaybackPhase) -> Bool {
        switch phase {
        case .pending, .sent, .preparing, .ready, .selected, .starting, .playing: true
        case .completed, .failed, .cancelled: false
        }
    }
}

/// Stores the handoff ledger locally on each playback device. The caller must
/// pass the current library owner and generation for every load and save.
@MainActor
public final class ListenNextPlaybackLedgerStore {
    private let defaults: UserDefaults
    private let key: String
    private let requesterDeviceID: String
    private let ownerToken: String
    private let operationGeneration: UInt64

    public init(defaults: UserDefaults, key: String, requesterDeviceID: String,
                ownerToken: String, operationGeneration: UInt64) {
        self.defaults = defaults
        self.key = key
        self.requesterDeviceID = requesterDeviceID
        self.ownerToken = ownerToken
        self.operationGeneration = operationGeneration
    }

    public func load() -> ListenNextPlaybackLedger {
        ListenNextPlaybackLedger.decode(
            defaults.data(forKey: key), requesterDeviceID: requesterDeviceID,
            ownerToken: ownerToken, operationGeneration: operationGeneration)
    }

    public func save(_ ledger: ListenNextPlaybackLedger) throws {
        guard ledger.requesterDeviceID == requesterDeviceID, ledger.ownerToken == ownerToken,
              ledger.operationGeneration == operationGeneration else { return }
        defaults.set(try ledger.encoded(), forKey: key)
    }
}
