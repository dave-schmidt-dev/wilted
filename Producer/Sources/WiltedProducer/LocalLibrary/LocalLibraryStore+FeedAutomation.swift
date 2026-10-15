import Foundation
import SwiftData
import WiltedDomain

private typealias FeedPolicyRecord = LocalLibrarySchemaV17Models.PodcastFeedPolicyRecord
private typealias MatchRuleRecord = LocalLibrarySchemaV16Models.EpisodeMatchRuleRecord
private typealias DecisionRecord = LocalLibrarySchemaV16Models.EpisodeDecisionRecord

public enum AutomaticEpisodeAdmissionError: Error, Equatable {
    case capacityUnavailable
    case manualDecisionExists
    case supersededManualDecision
    case episodeUnavailable
}

extension LocalLibraryStore {
    #if DEBUG
    /// Test-only seam reached after every V16 admission write is staged and
    /// before its sole save. A thrown error leaves all staged rows uncommitted.
    @TaskLocal static var feedAutomationBeforeSave: (@Sendable () throws -> Void)?
    #endif

    private static func decodePolicy(_ record: FeedPolicyRecord) throws -> FeedAutomationPolicy {
        guard let autoKeep = FeedAutomationOverride(rawValue: record.autoKeep),
              let autoDownload = FeedAutomationOverride(rawValue: record.autoDownload),
              let autoPrepare = FeedAutomationOverride(rawValue: record.autoPrepare) else {
            throw LocalLibraryStoreError.invalidFeedAutomationPolicy("corrupt override")
        }
        guard record.keptLimit == nil || record.keptLimit! > 0 else {
            throw LocalLibraryStoreError.invalidFeedAutomationPolicy("kept limit must be positive")
        }
        return FeedAutomationPolicy(
            autoKeep: autoKeep, autoDownload: autoDownload, autoPrepare: autoPrepare,
            keptLimit: record.keptLimit.map(FeedKeptLimitOverride.explicit) ?? .useGlobal
        )
    }

    private static func decodeRule(_ record: MatchRuleRecord) throws -> EpisodeMatchRule {
        guard let field = EpisodeMatchField(rawValue: record.field),
              let action = EpisodeMatchAction(rawValue: record.action) else {
            throw LocalLibraryStoreError.invalidFeedAutomationPolicy("corrupt match rule")
        }
        return EpisodeMatchRule(id: record.id, field: field, includePattern: record.includePattern,
                                excludePattern: record.excludePattern, action: action, isEnabled: record.enabled)
    }

    private static func decodeDecision(_ record: DecisionRecord) throws -> EpisodeDecisionRecord {
        guard let episodeID = try? ItemID(rawValue: record.episodeID),
              let decision = EpisodeDecision(rawValue: record.decision),
              let source = EpisodeDecisionSource(rawValue: record.source) else {
            throw LocalLibraryStoreError.invalidFeedAutomationPolicy("corrupt episode decision")
        }
        return EpisodeDecisionRecord(episodeID: episodeID, decision: decision, source: source,
                                     ruleID: record.ruleID, decidedAt: Timestamp(record.decidedAt))
    }

    /// Returns a feed's local policy, or the fully inheriting policy when the
    /// feed has no V16 row yet.
    public func feedAutomationPolicy(for feedID: ItemID) throws -> FeedAutomationPolicy {
        let context = ModelContext(container)
        guard let record = try context.fetch(FetchDescriptor<FeedPolicyRecord>())
            .first(where: { $0.feedID == feedID.rawValue }) else { return FeedAutomationPolicy() }
        return try Self.decodePolicy(record)
    }

    /// Inserts or overwrites one feed's policy. Explicit kept limits are
    /// checked here as well as on read so invalid values never reach disk.
    public func save(feedAutomationPolicy policy: FeedAutomationPolicy, for feedID: ItemID,
                     updatedAt: Timestamp = Timestamp(Date())) throws {
        let keptLimit: Int?
        switch policy.keptLimit {
        case .useGlobal: keptLimit = nil
        case let .explicit(value):
            guard value > 0 else { throw LocalLibraryStoreError.invalidFeedAutomationPolicy("kept limit must be positive") }
            keptLimit = value
        }
        let context = ModelContext(container)
        if let record = try context.fetch(FetchDescriptor<FeedPolicyRecord>()).first(where: { $0.feedID == feedID.rawValue }) {
            record.autoKeep = policy.autoKeep.rawValue; record.autoDownload = policy.autoDownload.rawValue
            record.autoPrepare = policy.autoPrepare.rawValue; record.keptLimit = keptLimit; record.updatedAt = updatedAt.date
        } else {
            context.insert(FeedPolicyRecord(feedID: feedID.rawValue, autoKeep: policy.autoKeep.rawValue,
                                            autoDownload: policy.autoDownload.rawValue, autoPrepare: policy.autoPrepare.rawValue,
                                            keptLimit: keptLimit, updatedAt: updatedAt.date))
        }
        try context.save()
    }

    /// Whether the feed is marked as news. A feed with no policy row, or a row
    /// written before the flag existed, is not news.
    public func isNews(feedID: ItemID) throws -> Bool {
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<FeedPolicyRecord>())
            .first(where: { $0.feedID == feedID.rawValue })?.isNews ?? false
    }

    /// Stores the news flag, creating an inheriting policy row when the feed
    /// has none. The other policy fields are left as they are.
    public func save(isNews: Bool, feedID: ItemID, updatedAt: Timestamp = Timestamp(Date())) throws {
        let context = ModelContext(container)
        if let record = try context.fetch(FetchDescriptor<FeedPolicyRecord>()).first(where: { $0.feedID == feedID.rawValue }) {
            record.isNews = isNews; record.updatedAt = updatedAt.date
        } else {
            let inheriting = FeedAutomationPolicy()
            context.insert(FeedPolicyRecord(feedID: feedID.rawValue, autoKeep: inheriting.autoKeep.rawValue,
                                            autoDownload: inheriting.autoDownload.rawValue,
                                            autoPrepare: inheriting.autoPrepare.rawValue, keptLimit: nil,
                                            updatedAt: updatedAt.date, isNews: isNews))
        }
        try context.save()
    }

    /// Reads a feed's rules in their persisted order.
    public func episodeMatchRules(for feedID: ItemID) throws -> EpisodeMatchRules {
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<MatchRuleRecord>())
            .filter { $0.feedID == feedID.rawValue }
            .sorted { $0.order == $1.order ? $0.id.uuidString < $1.id.uuidString : $0.order < $1.order }
        return EpisodeMatchRules(rules: try records.map(Self.decodeRule))
    }

    /// Replaces a feed's complete ordered rule set after validating its regular
    /// expressions. Storage order is normalized to contiguous array indices.
    public func replaceEpisodeMatchRules(_ rules: EpisodeMatchRules, for feedID: ItemID,
                                         updatedAt: Timestamp = Timestamp(Date())) throws {
        try rules.validate()
        let context = ModelContext(container)
        for record in try context.fetch(FetchDescriptor<MatchRuleRecord>()) where record.feedID == feedID.rawValue {
            context.delete(record)
        }
        for (order, rule) in rules.rules.enumerated() {
            context.insert(MatchRuleRecord(id: rule.id, feedID: feedID.rawValue, order: order,
                                           field: rule.field.rawValue, includePattern: rule.includePattern,
                                           excludePattern: rule.excludePattern, action: rule.action.rawValue,
                                           enabled: rule.isEnabled, updatedAt: updatedAt.date))
        }
        try context.save()
    }

    public func episodeDecision(for episodeID: ItemID) throws -> EpisodeDecisionRecord? {
        let context = ModelContext(container)
        guard let record = try context.fetch(FetchDescriptor<DecisionRecord>())
            .first(where: { $0.episodeID == episodeID.rawValue }) else { return nil }
        return try Self.decodeDecision(record)
    }

    @discardableResult
    public func save(episodeDecision value: EpisodeDecisionRecord) throws -> PodcastEpisodeDecisionWriteResult {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        defer { if context.hasChanges { context.rollback() } }
        let lookup = try EpisodeAssociationReadLookup(in: context)
        let applies = try Self.shouldApplyEpisodeDecision(value, in: context, lookup: lookup)
        try Self.stageAssociationManualTie(value, in: context, lookup: lookup)
        guard applies else {
            if context.hasChanges { try context.save() }
            return .superseded
        }
        if let record = try context.fetch(FetchDescriptor<DecisionRecord>())
            .first(where: { $0.episodeID == value.episodeID.rawValue }) {
            record.decision = value.decision.rawValue; record.source = value.source.rawValue
            record.ruleID = value.ruleID; record.decidedAt = value.decidedAt.date
        } else {
            context.insert(DecisionRecord(episodeID: value.episodeID.rawValue, decision: value.decision.rawValue,
                                          source: value.source.rawValue, ruleID: value.ruleID, decidedAt: value.decidedAt.date))
        }
        try context.save()
        return .applied
    }

    public func decisions(forFeed feedID: ItemID) throws -> [EpisodeDecisionRecord] {
        let context = ModelContext(container)
        let episodeIDs = Set(try context.fetch(FetchDescriptor<LocalLibrarySchemaV13Models.PodcastEpisodeRecord>())
            .filter { $0.feedID == feedID.rawValue }.map(\.id))
        return try context.fetch(FetchDescriptor<DecisionRecord>())
            .filter { episodeIDs.contains($0.episodeID) }.map(Self.decodeDecision)
    }

    /// Puts decision records and the queue back to an earlier state in one
    /// save. A `nil` value returns that episode to undecided by deleting its
    /// record; a non-nil value is written as it was. Used only to undo or roll
    /// back automatic changes, never to record a new decision.
    ///
    /// `unretiring` names episodes a rule Skip retired. Each one still
    /// retired returns to the feed in the same save as its decision, as
    /// `restoreEpisodes` returns it, so no failure can leave it retired
    /// without its skip record or live with one. Its audio is not restored.
    public func restoreEpisodeDecisions(_ prior: [ItemID: EpisodeDecisionRecord?], queue: PodcastQueueState,
                                        unretiring: Set<ItemID> = [],
                                        addedAt: Timestamp = Timestamp(Date())) throws {
        let context = ModelContext(container)
        // Automatic rollback cannot replace a newer explicit member choice.
        let lookup = try EpisodeAssociationReadLookup(in: context)
        let protected = Set(prior.keys.filter {
            lookup.state(for: $0)?.manualDecision != nil
        })
        let permittedUnretirement = unretiring.subtracting(protected)
        if !permittedUnretirement.isEmpty { try Self.stageUnretirement(Array(permittedUnretirement), asOwnerChoice: false, in: context) }
        let records = try context.fetch(FetchDescriptor<DecisionRecord>())
        for (episodeID, value) in prior {
            guard !protected.contains(episodeID) else { continue }
            let existing = records.first { $0.episodeID == episodeID.rawValue }
            switch (existing, value) {
            case let (record?, nil):
                context.delete(record)
            case let (record?, value?):
                record.decision = value.decision.rawValue; record.source = value.source.rawValue
                record.ruleID = value.ruleID; record.decidedAt = value.decidedAt.date
            case let (nil, value?):
                context.insert(DecisionRecord(episodeID: episodeID.rawValue, decision: value.decision.rawValue,
                                              source: value.source.rawValue, ruleID: value.ruleID,
                                              decidedAt: value.decidedAt.date))
            case (nil, nil):
                break
            }
        }
        let queueRecords = try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastQueueRecord>())
        let existingDates = Dictionary(queueRecords.map { ($0.episodeID, $0.addedAt) }, uniquingKeysWith: { first, _ in first })
        for record in queueRecords { context.delete(record) }
        // Preserve the current membership of protected members while reverting
        // only the automatic operation's other queue changes.
        let protectedRaw = Set(protected.map(\.rawValue))
        var restoredIDs = queue.episodeIDs.filter { !protected.contains($0) }
        for record in queueRecords.sorted(by: { $0.position < $1.position }) where protectedRaw.contains(record.episodeID) {
            let id = try ItemID(rawValue: record.episodeID)
            let position = min(record.position % Self.podcastCurrentPositionOffset, restoredIDs.count)
            restoredIDs.insert(id, at: position)
        }
        let protectedCurrent = queueRecords.first {
            protectedRaw.contains($0.episodeID) && $0.position >= Self.podcastCurrentPositionOffset
        }?.episodeID
        for (position, episodeID) in restoredIDs.enumerated() {
            let current = protectedCurrent.map { $0 == episodeID.rawValue }
                ?? (episodeID == queue.currentEpisodeID && !protected.contains(episodeID))
            let storedPosition = position + (current ? Self.podcastCurrentPositionOffset : 0)
            context.insert(LocalLibrarySchemaV6Models.PodcastQueueRecord(
                try PodcastQueueEntry(episodeID: episodeID, position: storedPosition,
                                      addedAt: Timestamp(existingDates[episodeID.rawValue] ?? addedAt.date))
            ))
        }
        #if DEBUG
        try Self.feedAutomationBeforeSave?()
        #endif
        try context.save()
    }

    /// Atomically appends an episode to the queue, records its decision, and
    /// find-or-inserts requested tickets. Existing queue rows and tickets are
    /// left unchanged, matching their public one-at-a-time counterparts.
    @discardableResult
    public func admitEpisode(_ value: EpisodeDecisionRecord, enqueue: Bool = true,
                             workTicketKinds: [WorkTicketKind] = [], requestedAt: Timestamp = Timestamp(Date()),
                             automaticKeptLimit: Int? = nil) throws -> [WorkTicket] {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        defer { if context.hasChanges { context.rollback() } }
        let episodeID = value.episodeID.rawValue
        let lookup = try EpisodeAssociationReadLookup(in: context)
        let applies = try Self.shouldApplyEpisodeDecision(value, in: context, lookup: lookup)
        try Self.stageAssociationManualTie(value, in: context, lookup: lookup)
        guard applies else {
            if context.hasChanges { try context.save() }
            // A dated manual action losing chronology is a clean per-item
            // no-op. The caller's batch can continue with independent items.
            if value.source == .manual { throw AutomaticEpisodeAdmissionError.supersededManualDecision }
            throw AutomaticEpisodeAdmissionError.manualDecisionExists
        }
        let queueRecords = try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastQueueRecord>())
        if value.source != .manual {
            let decisions = Array(lookup.decisions.values)
            guard decisions.first(where: { $0.episodeID == episodeID })?.source != EpisodeDecisionSource.manual.rawValue else {
                throw AutomaticEpisodeAdmissionError.manualDecisionExists
            }
            if enqueue, value.decision == .keep,
               !queueRecords.contains(where: { $0.episodeID == episodeID }) {
                let episodes = Array(lookup.episodes.values)
                guard let episode = episodes.first(where: { $0.id == episodeID }), episode.removalKind == nil else {
                    throw AutomaticEpisodeAdmissionError.episodeUnavailable
                }
                let persistedLimit = try context.fetch(FetchDescriptor<FeedPolicyRecord>())
                    .first(where: { $0.feedID == episode.feedID })?.keptLimit
                if let limit = persistedLimit ?? automaticKeptLimit {
                    let liveIDs = Set(episodes.filter { $0.feedID == episode.feedID && $0.removalKind == nil }.map(\.id))
                    let keptDecisions = Set(decisions.filter { $0.decision == EpisodeDecision.keep.rawValue }.map(\.episodeID))
                    let rawKept = Set(queueRecords.map(\.episodeID)).union(keptDecisions).intersection(liveIDs).subtracting([episodeID])
                    let candidateGroup = lookup.state(for: value.episodeID)?.representativeID ?? value.episodeID
                    let kept = try Set(rawKept.map { raw -> ItemID in
                        let id = try ItemID(rawValue: raw)
                        return lookup.state(for: id)?.representativeID ?? id
                    }).subtracting([candidateGroup]).count
                    let feedID = try ItemID(rawValue: episode.feedID)
                    let reserved = try manualCompletionCapacityReservations(at: requestedAt.date)[feedID, default: 0]
                    guard kept + reserved < limit else { throw AutomaticEpisodeAdmissionError.capacityUnavailable }
                }
            }
        }
        if enqueue, !queueRecords.contains(where: { $0.episodeID == episodeID }) {
            let lastPosition = queueRecords.map { $0.position >= Self.podcastCurrentPositionOffset
                ? $0.position - Self.podcastCurrentPositionOffset : $0.position }.max() ?? -1
            context.insert(LocalLibrarySchemaV6Models.PodcastQueueRecord(
                try PodcastQueueEntry(episodeID: value.episodeID, position: lastPosition + 1, addedAt: requestedAt)
            ))
        }
        if let record = lookup.decisions.values.first(where: { $0.episodeID == episodeID }) {
            record.decision = value.decision.rawValue; record.source = value.source.rawValue
            record.ruleID = value.ruleID; record.decidedAt = value.decidedAt.date
        } else {
            context.insert(DecisionRecord(episodeID: episodeID, decision: value.decision.rawValue,
                                          source: value.source.rawValue, ruleID: value.ruleID, decidedAt: value.decidedAt.date))
        }
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV12Models.WorkTicketRecord>())
        let nextSequence = (records.map(\.requestSequence).max() ?? 0) + 1
        var tickets: [WorkTicket] = []
        for (offset, kind) in Array(Set(workTicketKinds.map(\.rawValue))).sorted().compactMap(WorkTicketKind.init(rawValue:)).enumerated() {
            let id = "\(kind.rawValue)|\(episodeID)"
            guard !records.contains(where: { $0.id == id }) else { continue }
            let ticket = WorkTicket(kind: kind, subjectID: episodeID, resolvedItemID: episodeID,
                                    requestSequence: nextSequence + offset, requestedAt: requestedAt, updatedAt: requestedAt)
            context.insert(LocalLibrarySchemaV12Models.WorkTicketRecord(ticket)); tickets.append(ticket)
        }
        #if DEBUG
        try Self.feedAutomationBeforeSave?()
        #endif
        try context.save()
        return tickets
    }

    /// Applies a match rule's Skip to one episode found by a refresh: retires
    /// it and records the skip, its rule source and the rule ID in one save,
    /// so History can name the rule and no crash can leave a retired episode
    /// without its reason (or a skip record on a live one).
    ///
    /// Retirement matches a manual Skip through `retireEpisodes`: `retiredAt`
    /// and the retired removal kind are set, and the episode's revision,
    /// download and artwork records go in the same save, their files only
    /// after it commits. A manual decision is the listener's and always wins:
    /// an episode restored from History carries a manual Keep, so a rule never
    /// retires it again. Returns false, writing nothing, for a missing or
    /// already removed episode or one with a manual decision.
    @discardableResult
    public func retireEpisodeBySkipRule(_ episodeID: ItemID, ruleID: UUID,
                                        at decidedAt: Timestamp = Timestamp(Date())) throws -> Bool {
        let context = ModelContext(container)
        let identifier = episodeID.rawValue
        guard let episode = try context.fetch(FetchDescriptor<LocalLibrarySchemaV13Models.PodcastEpisodeRecord>())
            .first(where: { $0.id == identifier }), episode.removalKind == nil else { return false }
        let existing = try context.fetch(FetchDescriptor<DecisionRecord>()).first { $0.episodeID == identifier }
        guard existing?.source != EpisodeDecisionSource.manual.rawValue else { return false }
        guard try !Self.associationHasManualChoice(for: episodeID, in: context) else { return false }
        episode.retiredAt = decidedAt.date
        episode.removalKind = PodcastEpisodeRemovalKind.retired.rawValue
        if let existing {
            existing.decision = EpisodeDecision.skip.rawValue; existing.source = EpisodeDecisionSource.rule.rawValue
            existing.ruleID = ruleID; existing.decidedAt = decidedAt.date
        } else {
            context.insert(DecisionRecord(episodeID: identifier, decision: EpisodeDecision.skip.rawValue,
                                          source: EpisodeDecisionSource.rule.rawValue, ruleID: ruleID,
                                          decidedAt: decidedAt.date))
        }
        let doomedMedia = try Self.deleteMediaRecords(forEpisodesWithIDs: [identifier], in: context)
        #if DEBUG
        try Self.feedAutomationBeforeSave?()
        #endif
        try context.save()
        deleteMediaIfUnreferenced(doomedMedia)
        return true
    }
}
