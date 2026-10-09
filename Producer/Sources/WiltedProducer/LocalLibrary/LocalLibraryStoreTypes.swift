import CryptoKit
import Foundation
import SwiftData
import WiltedDomain
import WiltedSync

/// The version of the local producer schema.  CloudKit mirroring is deliberately
/// not configured here; this store is the producer's local source of truth.
public enum LocalLibrarySchemaVersion: Int, Codable, Sendable {
    case v1 = 1
    case v2 = 2
    case v3 = 3
    case v4 = 4
    case v5 = 5
    case v6 = 6
    case v7 = 7
    case v8 = 8
    case v9 = 9
    case v10 = 10
    case v11 = 11
    case v12 = 12
    case v13 = 13
    case v14 = 14
    case v15 = 15
    case v16 = 16
    case v17 = 17

    public static let current: LocalLibrarySchemaVersion = .v17
}

/// The local ownership state used by generation-based remote reconciliation.
public enum LocalLibrarySyncStatus: String, Codable, Sendable {
    case remoteAcknowledged
    case localOnly
    case pendingUpload
    case conflicted
    case failedUpload
}

/// Opaque CKSyncEngine state and the timestamps of the last successful operations.
public struct LocalLibrarySyncState: Codable, Equatable, Sendable {
    public let key: String
    public let engineState: Data
    public let lastFetchAt: Timestamp?
    public let lastSendAt: Timestamp?

    public init(key: String, engineState: Data = Data(), lastFetchAt: Timestamp? = nil, lastSendAt: Timestamp? = nil) {
        self.key = key
        self.engineState = engineState
        self.lastFetchAt = lastFetchAt
        self.lastSendAt = lastSendAt
    }
}

/// A durable local deletion request. It remains until the remote deletion is acknowledged.
public struct LocalLibraryTombstone: Codable, Equatable, Sendable {
    public let id: String
    public let itemID: ItemID
    public let generationID: String?
    public let requestedAt: Timestamp
    public let remoteAcknowledged: Bool

    public init(id: String, itemID: ItemID, generationID: String? = nil, requestedAt: Timestamp,
                remoteAcknowledged: Bool = false) {
        self.id = id
        self.itemID = itemID
        self.generationID = generationID
        self.requestedAt = requestedAt
        self.remoteAcknowledged = remoteAcknowledged
    }
}

/// Opaque system fields and change tag needed for an optimistic playback save/delete.
public struct PlaybackSystemFieldsSidecar: Codable, Equatable, Sendable {
    public let encodedSystemFields: Data?
    public let changeTag: String?

    public init(encodedSystemFields: Data? = nil, changeTag: String? = nil) {
        self.encodedSystemFields = encodedSystemFields
        self.changeTag = changeTag
    }
}

/// The deterministic result of finalizing one full-zone fetch generation.
public struct LocalLibrarySnapshotResult: Equatable, Sendable {
    public let generationID: String
    public let deletedItemIDs: [ItemID]
    public let retainedItemIDs: [ItemID]
    public let mutated: Bool

    public init(generationID: String, deletedItemIDs: [ItemID], retainedItemIDs: [ItemID], mutated: Bool) {
        self.generationID = generationID
        self.deletedItemIDs = deletedItemIDs
        self.retainedItemIDs = retainedItemIDs
        self.mutated = mutated
    }
}

/// One validated sync transaction applied to the local SwiftData source of truth.
public struct LocalLibrarySyncCommit: Sendable {
    /// A decoded item and its ownership status to apply in the transaction.
    public struct ArticleApply: Sendable {
        public let article: Article
        public let status: LocalLibrarySyncStatus

        public init(article: Article, status: LocalLibrarySyncStatus) {
            self.article = article; self.status = status
        }
    }

    /// A decoded revision backed by already validated local media.
    public struct RevisionApply: Sendable {
        public let revision: AudioRevision
        public let mediaURL: URL

        public init(revision: AudioRevision, mediaURL: URL) {
            self.revision = revision; self.mediaURL = mediaURL
        }
    }

    /// A decoded playback state and its opaque CloudKit sidecar.
    public struct PlaybackApply: Sendable {
        public let state: PlaybackState
        public let sidecar: PlaybackSystemFieldsSidecar

        public init(state: PlaybackState, sidecar: PlaybackSystemFieldsSidecar) {
            self.state = state; self.sidecar = sidecar
        }
    }

    /// A decoded transcript bound to an existing immutable revision identity.
    public struct TranscriptApply: Sendable {
        public let transcript: Transcript

        public init(transcript: Transcript) {
            self.transcript = transcript
        }
    }

    /// A status-only update for an existing item, used by send outcomes.
    public struct StatusApply: Sendable {
        public let recordID: WiltedRecordID
        public let status: LocalLibrarySyncStatus

        public init(recordID: WiltedRecordID, status: LocalLibrarySyncStatus) {
            self.recordID = recordID; self.status = status
        }
    }

    public let state: SyncRepositoryState
    public let articles: [ArticleApply]
    public let revisions: [RevisionApply]
    public let transcripts: [TranscriptApply]
    public let playbacks: [PlaybackApply]
    public let statusUpdates: [StatusApply]
    public let deletions: [WiltedRecordID]
    public let lastFetchAt: Timestamp?
    public let lastSendAt: Timestamp?

    public init(state: SyncRepositoryState, articles: [ArticleApply] = [], revisions: [RevisionApply] = [],
                transcripts: [TranscriptApply] = [],
                playbacks: [PlaybackApply] = [], statusUpdates: [StatusApply] = [], deletions: [WiltedRecordID] = [],
                lastFetchAt: Timestamp? = nil, lastSendAt: Timestamp? = nil) {
        self.state = state; self.articles = articles; self.revisions = revisions; self.transcripts = transcripts
        self.playbacks = playbacks; self.statusUpdates = statusUpdates; self.deletions = deletions
        self.lastFetchAt = lastFetchAt; self.lastSendAt = lastSendAt
    }
}

/// Where an immutable-revision violation was detected.
///
/// Seven call sites raise the same invariant failure, and without this a
/// reproduction can only say "some identity mismatch", never which write was
/// refused. The raw values are stable names for diagnostics; nothing persists
/// them.
public enum ImmutableRevisionSite: String, CaseIterable, Equatable, Sendable {
    /// `saveReadyRevision(_:mediaURL:)` found an existing record that differs.
    case readyRevision
    /// `saveReadyRevision(_:mediaURL:transcript:)` found an existing record that differs.
    case readyRevisionWithTranscript
    /// `saveReadyRevision(_:mediaURL:transcript:outcome:)` found an existing record that differs.
    case readyRevisionWithOutcome
    /// `applySyncCommit(_:)` tried to write a revision identity the store holds differently.
    case syncCommit
    /// `finalizePodcastDownload(revision:mediaURL:download:)` found an existing record that differs.
    case finalizedDownload
    /// `replaceReadyRevision` was asked to supersede the revision it is writing.
    case replacementSupersedesItself
    /// `replaceReadyRevision` found an existing record for the new revision that differs.
    case replacement
}

public enum LocalLibraryStoreError: Error, Equatable, Sendable {
    case immutableRevision(RevisionID, site: ImmutableRevisionSite)
    case revisionBelongsToDifferentItem
    case invalidPreparationStatus(String)
    case invalidPodcastState(String)
    case migrationPreflightFailed(String)
    case invalidWorkTicketTransition(from: String, to: String)
    case invalidFeedAutomationPolicy(String)
    /// The on-disk store matches no schema this build knows -- typically a
    /// newer build's store. Nothing was written, checkpointed or copied.
    case incompatibleStoreVersion(String)
    /// `migrate: false` was asked to open a store that needs a migration.
    /// Nothing was written.
    case migrationRequired(fromVersion: Int)
    /// A forward migration failed after the backup was taken; the original
    /// files were restored from `backupURL`, which is retained.
    case migrationFailedRestored(backupURL: URL, reason: String)
    /// A forward migration failed and restoring the original also failed.
    /// The retained backup at `backupURL` is intact; see
    /// docs/statistics-migration-recovery.md for the manual restore.
    case migrationRestoreFailed(backupURL: URL, reason: String)
    /// Only one summary rebuild runs at a time.
    case statisticsRebuildInProgress
}

/// One progress report from `rebuildLifetimeStatisticsSummary`.
public struct LifetimeStatisticsRebuildProgress: Equatable, Sendable {
    public enum Phase: String, Sendable {
        case measuredLedger
        case legacyLedger
        case published
    }

    public let phase: Phase
    /// Ledger rows read so far, across both ledgers.
    public let processedEvents: Int
    /// Ledger rows counted when the rebuild started. Rows appended during the
    /// rebuild can make `processedEvents` exceed it.
    public let totalEvents: Int

    public init(phase: Phase, processedEvents: Int, totalEvents: Int) {
        self.phase = phase; self.processedEvents = processedEvents; self.totalEvents = totalEvents
    }
}

/// The media files writers own before any record names them.
///
/// A download's staging file, a synthesis candidate, and an assembler's
/// temporary file all exist on disk while the store still has no revision for
/// them. The reclaim audit consults this registry, so a sweep can only delete
/// files that no writer holds and no record names.
public final class MediaInFlightRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: Set<String> = []

    public init() {}

    public func begin(_ url: URL) { lock.withLock { _ = paths.insert(url.standardizedFileURL.path) } }
    public func end(_ url: URL) { lock.withLock { _ = paths.remove(url.standardizedFileURL.path) } }
    public func isInFlight(_ url: URL) -> Bool { lock.withLock { paths.contains(url.standardizedFileURL.path) } }
    public var inFlightPaths: Set<String> { lock.withLock { paths } }
}
