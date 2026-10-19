import Foundation
import SwiftData
import WiltedDomain

/// What a playback checkpoint write did.
public enum PlaybackSaveOutcome: Equatable, Sendable {
    case saved
    /// Nothing was written: the item has no episode row, no article row and
    /// no stored audio for that revision, so a new playback record would
    /// outlive the removal that deleted them.
    case skippedMissingItem
}

extension LocalLibraryStore {
    /// Upserts a playback checkpoint. A first record for an item that no
    /// longer exists is skipped rather than inserted: a pause that lands
    /// after an unsubscribe cascade would otherwise re-create the position
    /// the cascade just deleted.
    @discardableResult
    public func save(playback state: PlaybackState) throws -> PlaybackSaveOutcome {
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV21Models.PlaybackRecord>())
        let id = "\(state.itemID.rawValue)|\(state.revisionID.rawValue)"
        let existingRecord = records.first(where: { $0.id == id })
        if existingRecord == nil, try !playbackOwnerExists(state, in: context) { return .skippedMissingItem }
        if let existing = existingRecord {
            existing.sessionID = state.sessionID; existing.sequence = state.sequence; existing.positionSeconds = state.positionSeconds
            existing.durationSeconds = state.durationSeconds; existing.completed = state.completed; existing.intent = state.intent.rawValue
            existing.deviceID = state.deviceID
            existing.updatedAt = state.updatedAt.date
        } else { context.insert(LocalLibrarySchemaV21Models.PlaybackRecord(state)) }
        try context.save()
        return .saved
    }

    /// Writes the completed playback checkpoint and the "finished listening"
    /// fact in one `ModelContext`/one save, so a crash between the two never
    /// leaves the checkpoint durable without the listening record, or vice
    /// versa. Skipped as a whole, like `save(playback:)`, when the item no
    /// longer exists and has no playback record yet.
    @discardableResult
    public func save(playback: PlaybackState, listening: PodcastListeningState) throws -> PlaybackSaveOutcome {
        let context = ModelContext(container)
        let playbackRecords = try context.fetch(FetchDescriptor<LocalLibrarySchemaV21Models.PlaybackRecord>())
        let playbackID = "\(playback.itemID.rawValue)|\(playback.revisionID.rawValue)"
        let existingRecord = playbackRecords.first(where: { $0.id == playbackID })
        if existingRecord == nil, try !playbackOwnerExists(playback, in: context) { return .skippedMissingItem }
        if let existing = existingRecord {
            existing.sessionID = playback.sessionID; existing.sequence = playback.sequence; existing.positionSeconds = playback.positionSeconds
            existing.durationSeconds = playback.durationSeconds; existing.completed = playback.completed; existing.intent = playback.intent.rawValue
            existing.deviceID = playback.deviceID
            existing.updatedAt = playback.updatedAt.date
        } else { context.insert(LocalLibrarySchemaV21Models.PlaybackRecord(playback)) }

        let listeningRecords = try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastListeningRecord>())
        if let existing = listeningRecords.first(where: { $0.id == listening.episodeID.rawValue }) {
            existing.completedAt = listening.completedAt?.date
            existing.lastRevisionID = listening.lastRevisionID?.rawValue
            existing.updatedAt = listening.updatedAt.date
        } else {
            context.insert(LocalLibrarySchemaV10Models.PodcastListeningRecord(listening))
        }
        try context.save()
        return .saved
    }

    /// Whether the checkpoint's item still has an episode row, an article row
    /// or stored audio for that exact revision to own a new playback record.
    /// An unsubscribe deletes all three in one save. A removed article keeps
    /// its flagged row, so it still counts.
    private func playbackOwnerExists(_ state: PlaybackState, in context: ModelContext) throws -> Bool {
        let identifier = state.itemID.rawValue
        let revisionIdentifier = state.revisionID.rawValue
        let episodes = FetchDescriptor<LocalLibrarySchemaV13Models.PodcastEpisodeRecord>(
            predicate: #Predicate { $0.id == identifier })
        if try context.fetchCount(episodes) > 0 { return true }
        let articles = FetchDescriptor<LocalLibrarySchemaV21Models.ArticleRecord>(
            predicate: #Predicate { $0.id == identifier })
        if try context.fetchCount(articles) > 0 { return true }
        let revisions = FetchDescriptor<LocalLibrarySchemaV3Models.RevisionRecord>(
            predicate: #Predicate { $0.id == revisionIdentifier && $0.itemID == identifier })
        return try context.fetchCount(revisions) > 0
    }

    public func playbackState(for itemID: ItemID, revisionID: RevisionID) throws -> PlaybackState? {
        let context = ModelContext(container)
        guard let record = try context.fetch(FetchDescriptor<LocalLibrarySchemaV21Models.PlaybackRecord>()).first(where: { $0.itemID == itemID.rawValue && $0.revisionID == revisionID.rawValue }) else { return nil }
        return try PlaybackState(itemID: itemID, revisionID: revisionID, sessionID: record.sessionID, sequence: record.sequence,
                                 positionSeconds: record.positionSeconds, durationSeconds: record.durationSeconds, completed: record.completed,
                                 intent: PlaybackIntent(rawValue: record.intent) ?? .progress, deviceID: record.deviceID,
                                 updatedAt: Timestamp(record.updatedAt))
    }

    // MARK: Sync state

    /// Saves opaque sync state and replaces both optional operation timestamps.
    public func save(syncState state: LocalLibrarySyncState) throws {
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.SyncStateRecord>())
        if let existing = records.first(where: { $0.key == state.key }) {
            existing.engineState = state.engineState
            existing.lastFetchAt = state.lastFetchAt?.date
            existing.lastSendAt = state.lastSendAt?.date
            existing.schemaVersion = LocalLibrarySchemaVersion.current.rawValue
        } else {
            context.insert(LocalLibrarySchemaV3Models.SyncStateRecord(state))
        }
        try context.save()
    }

    /// Loads the persisted state for one sync-zone key.
    public func syncState(for key: String) throws -> LocalLibrarySyncState? {
        let context = ModelContext(container)
        guard let record = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.SyncStateRecord>()).first(where: { $0.key == key }) else { return nil }
        return LocalLibrarySyncState(key: record.key, engineState: record.engineState,
                                     lastFetchAt: record.lastFetchAt.map(Timestamp.init), lastSendAt: record.lastSendAt.map(Timestamp.init))
    }

    // MARK: Library publisher account binding

    /// Saves which iCloud account owns this device's library publishing.
    ///
    /// Kept in its own sync-state row, `LocalLibraryAccountBinding.storageKey`, apart from
    /// the `private-zone` sync state and from any device identifier.
    public func save(libraryAccountBinding binding: LocalLibraryAccountBinding) throws {
        try save(syncState: LocalLibrarySyncState(
            key: LocalLibraryAccountBinding.storageKey, engineState: try JSONEncoder().encode(binding)))
    }

    /// The persisted library account binding, or nil when no account was ever bound.
    ///
    /// - Throws: `LocalLibraryAccountBindingError` when the row is unreadable or holds a
    ///   token that is not a hash, so a damaged binding is never treated as unbound.
    public func libraryAccountBinding() throws -> LocalLibraryAccountBinding? {
        guard let state = try syncState(for: LocalLibraryAccountBinding.storageKey) else { return nil }
        do { return try JSONDecoder().decode(LocalLibraryAccountBinding.self, from: state.engineState) }
        catch let error as LocalLibraryAccountBindingError { throw error }
        catch { throw LocalLibraryAccountBindingError.corrupt }
    }

    // MARK: Podcast catalog and local listening state

}

/// Which iCloud account owns this device's library publishing.
///
/// Holds only hashed account tokens (`sha256:` and 64 lowercase hex digits, as produced by
/// `CloudKitAccountIdentity.token(for:)`), never a raw account identifier. Construction and
/// decoding both reject anything else.
public struct LocalLibraryAccountBinding: Codable, Equatable, Sendable {
    /// The sync-state row that stores the binding.
    public static let storageKey = "library-account-owner"

    public enum State: String, Codable, Sendable {
        /// `ownerToken` owns the library. Sending resumes once this launch sees that account.
        case bound
        /// A nonempty library that no account had claimed met `candidateToken`; the owner
        /// must approve before anything is sent.
        case reviewRequired
        /// The account changed away from `ownerToken`. Local work stays bound to that owner
        /// until the owner reviews it; `candidateToken` is the account now seen, if known.
        case quarantined
        /// The owner approved after a change that named no account; the next account seen
        /// becomes the owner.
        case approved
    }

    /// Why sending stopped for review.
    public enum Reason: String, Codable, Sendable {
        case unboundLibrary
        case signIn
        case signOut
        case switchAccounts
        case ownerMismatch
    }

    public let state: State
    public let ownerToken: String?
    public let candidateToken: String?
    public let reason: Reason?
    public let updatedAt: Timestamp

    public init(state: State, ownerToken: String? = nil, candidateToken: String? = nil,
                reason: Reason? = nil, updatedAt: Timestamp = Timestamp(Date())) throws {
        for token in [ownerToken, candidateToken].compactMap({ $0 }) where !Self.isHashedToken(token) {
            throw LocalLibraryAccountBindingError.unhashedToken
        }
        switch state {
        case .bound where ownerToken == nil:
            throw LocalLibraryAccountBindingError.invalidState("a bound library needs an owner")
        case .reviewRequired where candidateToken == nil:
            throw LocalLibraryAccountBindingError.invalidState("review needs the account to approve")
        default: break
        }
        self.state = state
        self.ownerToken = ownerToken
        self.candidateToken = candidateToken
        self.reason = reason
        self.updatedAt = updatedAt
    }

    /// True for `sha256:` followed by exactly 64 lowercase hex digits.
    public static func isHashedToken(_ token: String) -> Bool {
        token.range(of: #"^sha256:[0-9a-f]{64}$"#, options: .regularExpression) != nil
    }

    private enum CodingKeys: String, CodingKey { case state, ownerToken, candidateToken, reason, updatedAt }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            state: try values.decode(State.self, forKey: .state),
            ownerToken: try values.decodeIfPresent(String.self, forKey: .ownerToken),
            candidateToken: try values.decodeIfPresent(String.self, forKey: .candidateToken),
            reason: try values.decodeIfPresent(Reason.self, forKey: .reason),
            updatedAt: try values.decode(Timestamp.self, forKey: .updatedAt))
    }
}

/// A library account binding that cannot be stored or trusted.
public enum LocalLibraryAccountBindingError: Error, Equatable, Sendable {
    /// A token was not a hash; raw account identifiers are never stored.
    case unhashedToken
    case invalidState(String)
    /// The stored row could not be decoded.
    case corrupt
}
