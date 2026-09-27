import CryptoKit
import Foundation
import SwiftData
import WiltedDomain
import WiltedSync

public struct LocalLibraryMigrationPreflight: Equatable, Sendable {
    public let sourceURL: URL
    public let retainedURL: URL
    public let retainedFiles: [URL]

    public init(sourceURL: URL, retainedURL: URL, retainedFiles: [URL]) {
        self.sourceURL = sourceURL; self.retainedURL = retainedURL; self.retainedFiles = retainedFiles
    }
}

public typealias PodcastFeedSubscription = PodcastSubscription
public typealias PodcastDownloadState = PodcastDownload
public typealias PodcastArtworkAsset = PodcastArtwork
public typealias UpNextEntry = PodcastQueueEntry
public typealias PodcastPlaybackRate = PodcastPlaybackSpeed

public struct StoredAudioRevision: Codable, Equatable, Sendable {
    public let revision: AudioRevision
    public let mediaURL: URL

    public var itemID: ItemID { revision.itemID }
    public var revisionID: RevisionID { revision.revisionID }

    public init(revision: AudioRevision, mediaURL: URL) {
        self.revision = revision
        self.mediaURL = mediaURL
    }
}

/// A durable preparation status associated with one producer request.
public struct PreparationJournalEntry: Codable, Equatable, Sendable {
    public let id: String
    public let itemID: ItemID
    public let requestID: String
    public let status: PreparationStatus

    public init(id: String, itemID: ItemID, requestID: String, status: PreparationStatus) {
        self.id = id
        self.itemID = itemID
        self.requestID = requestID
        self.status = status
    }
}

/// The result of reconciling podcast preparation attempts against the current
/// semantic pipeline. The store returns IDs rather than starting work so the
/// app can admit redownloads only after its library rows are loaded.
public struct PodcastPreparationInvalidationResult: Equatable, Sendable {
    public let resetEpisodeIDs: [ItemID]
    public let forcedRedownloadEpisodeIDs: [ItemID]

    public init(resetEpisodeIDs: [ItemID] = [], forcedRedownloadEpisodeIDs: [ItemID] = []) {
        self.resetEpisodeIDs = resetEpisodeIDs
        self.forcedRedownloadEpisodeIDs = forcedRedownloadEpisodeIDs
    }
}

/// Orders journal events without relying on SwiftData's undefined ordering for
/// rows emitted at the same instant. Event IDs carry a numeric ordinal when
/// they were written by the pipeline; legacy or externally-created IDs fall
/// back to their complete ID so their order is still stable.
func preparationEntryPrecedes(_ lhs: PreparationJournalEntry, _ rhs: PreparationJournalEntry) -> Bool {
    if lhs.status.emittedAt.date != rhs.status.emittedAt.date {
        return lhs.status.emittedAt.date < rhs.status.emittedAt.date
    }

    let lhsOrdinal = preparationOrdinal(in: lhs.id)
    let rhsOrdinal = preparationOrdinal(in: rhs.id)
    switch (lhsOrdinal, rhsOrdinal) {
    case let (left?, right?) where left != right:
        return left < right
    case (_?, nil):
        return true
    case (nil, _?):
        return false
    default:
        return lhs.id < rhs.id
    }
}

private func preparationOrdinal(in id: String) -> Int? {
    guard let marker = id.lastIndex(of: "#") else { return nil }
    let suffix = id[id.index(after: marker)...]
    guard !suffix.isEmpty, let ordinal = Int(suffix), ordinal >= 1 else { return nil }
    return ordinal
}

/// One preparation attempt, summarised from its journal entries.
///
/// The journal records every status a run emitted, which is the right shape
/// for diagnosis and the wrong shape for a list: a single article produces a
/// dozen rows. This collapses a run to what a reader needs — what it was
/// working on, where it got to, and whether it finished.
public struct PreparationRunSummary: Equatable, Sendable, Identifiable {
    public let requestID: String
    public let itemID: ItemID
    public let startedAt: Timestamp
    public let updatedAt: Timestamp
    public let stage: PreparationStage
    public let detail: String
    public let fraction: Double?
    public let isTerminal: Bool
    public let outcome: PreparationOutcome?
    public let failure: ProducerError?
    /// Every status the run journalled, oldest first. The summary fields
    /// above describe where the run is; this is how it got there.
    public let entries: [PreparationJournalEntry]

    public var id: String { requestID }

    public init(
        requestID: String,
        itemID: ItemID,
        startedAt: Timestamp,
        updatedAt: Timestamp,
        stage: PreparationStage,
        detail: String,
        fraction: Double?,
        isTerminal: Bool,
        outcome: PreparationOutcome?,
        failure: ProducerError?,
        entries: [PreparationJournalEntry] = []
    ) {
        self.requestID = requestID
        self.itemID = itemID
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.stage = stage
        self.detail = detail
        self.fraction = fraction
        self.isTerminal = isTerminal
        self.outcome = outcome
        self.failure = failure
        self.entries = entries
    }
}

public struct LocalLibraryInspection: Equatable, Sendable {
    public let schemaVersion: LocalLibrarySchemaVersion
    public let articleCount: Int
    public let revisionCount: Int
    public let preparationCount: Int
    public let playbackCount: Int
    public let transcriptCount: Int
}
