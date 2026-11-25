import Foundation
import SwiftData
import WiltedDomain
import WiltedLibrary

/// The result of one conditional phone Keep or Skip.
public struct NewEpisodeIntentCommit: Equatable, Sendable {
    public let outcome: IntentOutcome
    /// True when the exact request already had a durable receipt.
    public let wasReplay: Bool
    /// Keep's download work is started only after its durable ticket is committed.
    public let shouldStartDownload: Bool
    public let changedEpisodeIDs: [ItemID]
    public let feedIDs: [ItemID]

    init(
        outcome: IntentOutcome, wasReplay: Bool = false, shouldStartDownload: Bool = false,
        changedEpisodeIDs: [ItemID] = [], feedIDs: [ItemID] = []
    ) {
        self.outcome = outcome
        self.wasReplay = wasReplay
        self.shouldStartDownload = shouldStartDownload
        self.changedEpisodeIDs = changedEpisodeIDs
        self.feedIDs = feedIDs
    }
}

extension LocalLibraryStore {
    /// The single existing sync-state row used as the durable receipt ledger.
    /// Keeping this in `SyncStateRecord` adds no SwiftData schema version.
    public static let newEpisodeIntentReceiptsKey = "new-episode-intent-receipts-v1"

    private struct NewEpisodeIntentReceipt: Codable, Equatable {
        let intent: LibraryIntent
        let outcome: IntentOutcome
    }

    private struct NewEpisodeIntentReceiptLedger: Codable {
        let version: Int
        var receipts: [String: NewEpisodeIntentReceipt]

        static let currentVersion = 1
        init(receipts: [String: NewEpisodeIntentReceipt]) {
            version = Self.currentVersion
            self.receipts = receipts
        }
    }

    /// Rechecks Mac's current Feeds projection and producer state, then applies Keep or Skip
    /// with its immutable outcome receipt in one ModelContext save. Replaying the same intent
    /// returns the saved outcome; reusing its id for different content is rejected.
    public func commitNewEpisodeIntent(
        _ intent: LibraryIntent,
        macCurrentlyProjectsNew: Bool,
        decidedAt: Date,
        downloadAfterKeep: Bool = false
    ) throws -> NewEpisodeIntentCommit {
        guard case let .decideNewEpisode(entryID, decision) = intent.action else {
            throw LocalLibraryStoreError.invalidPodcastState("not a conditional New episodes intent")
        }

        let context = ModelContext(container)
        context.autosaveEnabled = false
        defer { if context.hasChanges { context.rollback() } }

        let syncRows = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.SyncStateRecord>())
        let receiptRow = syncRows.first { $0.key == Self.newEpisodeIntentReceiptsKey }
        var receipts: [String: NewEpisodeIntentReceipt] = [:]
        if let receiptRow {
            do {
                let ledger = try JSONDecoder().decode(NewEpisodeIntentReceiptLedger.self, from: receiptRow.engineState)
                guard ledger.version == NewEpisodeIntentReceiptLedger.currentVersion else {
                    throw LocalLibraryStoreError.invalidPodcastState("unsupported New episodes receipt version")
                }
                receipts = ledger.receipts
            } catch let error as LocalLibraryStoreError {
                throw error
            } catch {
                // A damaged ledger cannot safely be discarded: an old receipt may prove
                // that a matching decision already committed before a process crash.
                throw LocalLibraryStoreError.invalidPodcastState("unreadable New episodes receipt ledger")
            }
        }
        if let existing = receipts[intent.id] {
            guard existing.intent == intent else {
                throw LocalLibraryStoreError.invalidPodcastState("New episodes intent id was reused")
            }
            return NewEpisodeIntentCommit(outcome: existing.outcome, wasReplay: true)
        }

        // Existing receipts win over age: a crash after this transaction must replay the
        // committed result even if the phone reconnects after ordinary intents expire.
        if let expired = try IntentRetention.expiryOutcome(for: intent, now: decidedAt) {
            receipts[intent.id] = NewEpisodeIntentReceipt(intent: intent, outcome: expired)
            try Self.persistNewEpisodeReceiptLedger(receipts, row: receiptRow, in: context)
            try context.save()
            return NewEpisodeIntentCommit(outcome: expired)
        }

        let lookup = try EpisodeAssociationReadLookup(in: context)
        let episode = lookup.episodes[entryID.rawValue]
        let logical = lookup.state(for: entryID)
        let members = logical?.memberIDs ?? [entryID]
        let representativeID = logical?.representativeID ?? entryID
        let associatedGroup = (logical?.memberIDs.count ?? 1) > 1
        let queueRows = try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastQueueRecord>())
        let queuedIDs = Set(queueRows.map(\.episodeID))
        let isQueued = members.contains { queuedIDs.contains($0.rawValue) }
        let audiobooks = try context.fetch(FetchDescriptor<LocalLibrarySchemaV17Models.AudiobookRecord>())
        let isAudiobook = audiobooks.contains { $0.id == entryID.rawValue }

        let hasManualChoice = logical?.manualDecision != nil
        let groupHasActiveMember = members.contains { lookup.episodes[$0.rawValue]?.removalKind == nil }
        let removal: LibraryRemoval = switch episode?.removalKind.flatMap(PodcastEpisodeRemovalKind.init(rawValue:)) {
        case .retired?: .retired
        case .dismissed?: .dismissed
        case nil: .none
        }
        let producerStillProjectsNew = episode != nil
            && entryID == representativeID
            && (!associatedGroup || logical?.isTerminal == false)
            && !hasManualChoice
            && LibraryUndecidedEpisodeProjection.isNewEpisodeCandidate(
                kind: .podcastEpisode, removal: removal,
                groupIsTerminal: associatedGroup ? logical?.isTerminal : nil,
                groupHasActiveMember: groupHasActiveMember, isQueued: isQueued, isAudiobook: isAudiobook
            )

        let currentState = Self.newEpisodeCurrentState(
            episode: episode, logical: logical, queued: isQueued, isAudiobook: isAudiobook
        )
        let canApply = macCurrentlyProjectsNew && producerStillProjectsNew
        let outcome: IntentOutcome
        var changed: [ItemID] = []
        var feedIDs: [ItemID] = []
        var shouldStartDownload = false
        var mediaToDelete: [URL] = []

        if !canApply {
            outcome = try .rejectedNewEpisode(for: intent, currentState: currentState, at: decidedAt)
        } else {
            let value = EpisodeDecisionRecord(
                episodeID: entryID,
                decision: decision == .keep ? .keep : .skip,
                source: .manual,
                decidedAt: Timestamp(intent.createdAt)
            )
            guard try Self.shouldApplyEpisodeDecision(value, in: context, lookup: lookup) else {
                let state = Self.newEpisodeCurrentState(
                    episode: episode, logical: logical, queued: isQueued, isAudiobook: isAudiobook
                )
                outcome = try .rejectedNewEpisode(for: intent, currentState: state, at: decidedAt)
                receipts[intent.id] = NewEpisodeIntentReceipt(intent: intent, outcome: outcome)
                try Self.persistNewEpisodeReceiptLedger(receipts, row: receiptRow, in: context)
                try context.save()
                return NewEpisodeIntentCommit(outcome: outcome)
            }
            try Self.stageAssociationManualTie(value, in: context, lookup: lookup)

            switch decision {
            case .keep:
                if let queueRow = queueRows.first(where: { $0.episodeID == entryID.rawValue }) {
                    _ = queueRow // The shared candidate guard normally makes this branch unreachable.
                } else {
                    let lastPosition = queueRows.map {
                        $0.position >= Self.podcastCurrentPositionOffset
                            ? $0.position - Self.podcastCurrentPositionOffset : $0.position
                    }.max() ?? -1
                    context.insert(LocalLibrarySchemaV6Models.PodcastQueueRecord(
                        try PodcastQueueEntry(episodeID: entryID, position: lastPosition + 1, addedAt: Timestamp(intent.createdAt))
                    ))
                }
                Self.saveManualDecision(value, using: lookup, in: context)
                if downloadAfterKeep {
                    let ticketRecords = try context.fetch(FetchDescriptor<LocalLibrarySchemaV22Models.WorkTicketRecord>())
                    let ticketID = "\(WorkTicketKind.podcastDownload.rawValue)|\(entryID.rawValue)"
                    if !ticketRecords.contains(where: { $0.id == ticketID }) {
                        let ticket = WorkTicket(
                            kind: .podcastDownload, subjectID: entryID.rawValue, resolvedItemID: entryID.rawValue,
                            requestSequence: (ticketRecords.map(\.requestSequence).max() ?? 0) + 1,
                            requestedAt: Timestamp(intent.createdAt), updatedAt: Timestamp(intent.createdAt)
                        )
                        context.insert(LocalLibrarySchemaV22Models.WorkTicketRecord(ticket))
                    }
                    shouldStartDownload = true
                }
                changed = [entryID]
                if let raw = episode?.feedID, let feedID = try? ItemID(rawValue: raw) { feedIDs = [feedID] }
            case .skip:
                let retired = members.filter { lookup.episodes[$0.rawValue]?.removalKind == nil }
                for id in retired {
                    guard let row = lookup.episodes[id.rawValue] else { continue }
                    row.retiredAt = intent.createdAt
                    row.removalKind = PodcastEpisodeRemovalKind.retired.rawValue
                }
                for id in members {
                    Self.stageRetirementManualDecision(id, at: Timestamp(intent.createdAt), lookup: lookup, in: context)
                }
                changed = retired
                if !retired.isEmpty, !associatedGroup {
                    mediaToDelete = try Self.deleteMediaRecords(forEpisodesWithIDs: Set(retired.map(\.rawValue)), in: context)
                }
                feedIDs = Set(members.compactMap { member -> ItemID? in
                    guard let rawFeedID = lookup.episodes[member.rawValue]?.feedID else { return nil }
                    return try? ItemID(rawValue: rawFeedID)
                }).sorted { $0.rawValue < $1.rawValue }
            }
            outcome = try .applied(for: intent, at: decidedAt)
        }

        receipts[intent.id] = NewEpisodeIntentReceipt(intent: intent, outcome: outcome)
        try Self.persistNewEpisodeReceiptLedger(receipts, row: receiptRow, in: context)
        try context.save()
        // Files are reclaimed only after the decision, media rows, and receipt commit together.
        if !mediaToDelete.isEmpty { deleteMediaIfUnreferenced(mediaToDelete) }
        return NewEpisodeIntentCommit(
            outcome: outcome, shouldStartDownload: shouldStartDownload,
            changedEpisodeIDs: changed, feedIDs: feedIDs
        )
    }

    private static func newEpisodeCurrentState(
        episode: LocalLibrarySchemaV13Models.PodcastEpisodeRecord?,
        logical: PodcastEpisodeLogicalState?, queued: Bool, isAudiobook: Bool
    ) -> LibraryNewEpisodeCurrentState {
        guard episode != nil, !isAudiobook else { return .unavailable }
        if logical?.manualDecision == .keep || queued { return .kept }
        if logical?.manualDecision == .skip || episode?.removalKind != nil { return .skipped }
        if (logical?.memberIDs.count ?? 1) > 1, logical?.isTerminal == true { return .noLongerNew }
        return .noLongerNew
    }

    private static func saveManualDecision(
        _ value: EpisodeDecisionRecord, using lookup: EpisodeAssociationReadLookup, in context: ModelContext
    ) {
        if let record = lookup.decisions[value.episodeID.rawValue] {
            record.decision = value.decision.rawValue
            record.source = value.source.rawValue
            record.ruleID = nil
            record.decidedAt = value.decidedAt.date
        } else {
            context.insert(LocalLibrarySchemaV16Models.EpisodeDecisionRecord(
                episodeID: value.episodeID.rawValue, decision: value.decision.rawValue,
                source: value.source.rawValue, ruleID: nil, decidedAt: value.decidedAt.date
            ))
        }
    }

    private static func persistNewEpisodeReceiptLedger(
        _ receipts: [String: NewEpisodeIntentReceipt],
        row: LocalLibrarySchemaV3Models.SyncStateRecord?,
        in context: ModelContext
    ) throws {
        let data = try JSONEncoder().encode(NewEpisodeIntentReceiptLedger(receipts: receipts))
        if let row {
            row.engineState = data
            row.schemaVersion = LocalLibrarySchemaVersion.current.rawValue
        } else {
            context.insert(LocalLibrarySchemaV3Models.SyncStateRecord(
                LocalLibrarySyncState(key: Self.newEpisodeIntentReceiptsKey, engineState: data)
            ))
        }
    }
}
