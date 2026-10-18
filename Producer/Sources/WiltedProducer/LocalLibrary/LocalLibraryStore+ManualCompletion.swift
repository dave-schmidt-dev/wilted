import Foundation
import SwiftData
import WiltedDomain

private typealias ReceiptRecord = LocalLibrarySchemaV19Models.ManualCompletionReceiptRecord
private typealias ListeningRecord = LocalLibrarySchemaV10Models.PodcastListeningRecord
private typealias DecisionRecord = LocalLibrarySchemaV16Models.EpisodeDecisionRecord
private typealias QueueRecord = LocalLibrarySchemaV6Models.PodcastQueueRecord
private typealias EpisodeRecord = LocalLibrarySchemaV13Models.PodcastEpisodeRecord

public struct PodcastManualCompletionResult: Sendable {
    public let operationID: UUID?
    public let committed: [ItemID]
    public let unresolved: [ItemID]
    public let undoAvailableUntil: Date?
}

/// All fields owned by completion, including nil and manual/rule provenance.
private struct CompletionListening: Codable, Equatable {
    var completedAt: Date?
    var revision: String?
    var updatedAt: Date
    init(_ record: ListeningRecord) {
        completedAt = record.completedAt; revision = record.lastRevisionID; updatedAt = record.updatedAt
    }
}
private struct CompletionDecision: Codable, Equatable {
    var decision: String
    var source: String
    var ruleID: UUID?
    var decidedAt: Date
    init(_ record: DecisionRecord) {
        decision = record.decision; source = record.source; ruleID = record.ruleID; decidedAt = record.decidedAt
    }
}
private struct CompletionRecoveryFeed: Decodable {
    let feedID: String
}

private struct CompletionMember: Codable {
    var episodeID: String
    // Raw ID plus the source record's creation generation prevents a receipt
    // attaching to a recreated record that happens to reuse the same ID.
    var generation: Date
    var feedID: String
    var priorListening: CompletionListening?
    var priorDecision: CompletionDecision?
    var priorRemoval: String?
    var priorRetiredAt: Date?
    var postListening: CompletionListening
    var postDecision: CompletionDecision
    var position: Int?
    var predecessor: String?
    var successor: String?
    var addedAt: Date?
    var wasCurrent: Bool
    var capacityReservation: Int
    var restored: Bool = false
    /// Capacity remains reserved until the receipt's Undo window expires.
    var reservesCapacity: Bool { !restored && capacityReservation > 0 }
}

extension LocalLibraryStore {
    /// One actor turn captures raw library state and its logical metadata without reentrant writes.
    public func podcastLibraryIdentitySnapshot(profile: PodcastLibrarySnapshotProfile = .full) throws -> (
        library: PodcastLibrarySnapshot, associations: [PodcastEpisodeAssociation], states: [ItemID: PodcastEpisodeLogicalState]
    ) {
        let library = try podcastLibrarySnapshot(profile: profile)
        let lookup = try EpisodeAssociationReadLookup(in: ModelContext(container))
        let associations = lookup.associations
        var states: [ItemID: PodcastEpisodeLogicalState] = [:]
        for association in associations {
            states[association.representativeID] = lookup.state(for: association.representativeID)
        }
        return (library, associations, states)
    }

    /// Retains every raw member while exposing one logical capacity identity.
    public func logicalEpisodeIDs(_ requested: [ItemID]) throws -> [ItemID] {
        try Self.expandedLogicalEpisodeIDs(requested, in: ModelContext(container))
    }

    public func logicalEpisodeRepresentatives(_ requested: [ItemID]) throws -> Set<ItemID> {
        let lookup = try EpisodeAssociationReadLookup(in: ModelContext(container))
        return Set(requested.map { lookup.state(for: $0)?.representativeID ?? $0 })
    }

    /// A read preflight for accurate intent outcomes; mutations repeat the guard atomically.
    public func episodeDecisionWouldApply(_ value: EpisodeDecisionRecord) throws -> Bool {
        try Self.shouldApplyEpisodeDecision(value, in: ModelContext(container))
    }

    /// A fresh local choice must follow the owner state this device already holds,
    /// including a clock corrected backwards. Explicit wire dates are never adjusted.
    static func freshLocalOwnerChoiceDate(_ requested: [ItemID], now: Date = Date(), in context: ModelContext) throws -> Date {
        var result = Date(timeIntervalSince1970: (now.timeIntervalSince1970 * 1_000).rounded(.up) / 1_000)
        let lookup = try EpisodeAssociationReadLookup(in: context)
        for id in requested {
            if let prior = lookup.state(for: id)?.manualDecidedAt?.date, prior >= result {
                result = Date(timeIntervalSince1970: (prior.timeIntervalSince1970 * 1_000).rounded(.up) / 1_000 + 0.001)
            }
        }
        return result
    }

    static func expandedLogicalEpisodeIDs(_ requested: [ItemID], in context: ModelContext) throws -> [ItemID] {
        let lookup = try EpisodeAssociationReadLookup(in: context)
        var seen = Set<ItemID>()
        return requested.flatMap { lookup.state(for: $0)?.memberIDs ?? [$0] }
            .filter { seen.insert($0).inserted }
    }

    /// One actor-isolated save owns completion, manual decision, retirement,
    /// queue removal and the durable rollback receipt. Audio and measured
    /// progress are never touched. A caller may inject a failure before save
    /// using the internal seam to prove there is no partly committed state.
    public func manuallyCompleteEpisodes(
        _ requested: [ItemID], at: Timestamp? = nil, localNow: Date = Date(),
        undoDuration: TimeInterval = 10
    ) throws -> PodcastManualCompletionResult {
        let choiceAt = try at ?? Timestamp(Self.freshLocalOwnerChoiceDate(requested, now: localNow, in: ModelContext(container)))
        return try stageManualCompletion(requested, at: choiceAt, undoDuration: undoDuration, beforeSave: nil,
            undoWindowStartedAt: localNow)
    }

    func stageManualCompletion(
        _ requested: [ItemID], at: Timestamp, undoDuration: TimeInterval,
        beforeSave: (() throws -> Void)?,
        contextFactory: (@Sendable () throws -> ModelContext)? = nil,
        undoWindowStartedAt: Date? = nil
    ) throws -> PodcastManualCompletionResult {
        // Internal fault qualification can open the same synthetic store with
        // a supported read-only configuration; staging and save stay identical.
        let context = try contextFactory?() ?? ModelContext(container)
        context.autosaveEnabled = false
        defer { if context.hasChanges { context.rollback() } }
        let lookup = try EpisodeAssociationReadLookup(in: context)
        let listening = lookup.listening
        let queue = try context.fetch(FetchDescriptor<QueueRecord>()).sorted(by: Self.completionQueuePrecedes)
        let operationID = UUID()
        let deadline = (undoWindowStartedAt ?? at.date).addingTimeInterval(max(0, undoDuration))
        var members: [CompletionMember] = []
        var unresolved: [ItemID] = []
        var seen = Set<ItemID>()
        var expandedSeen = Set<ItemID>()
        let expanded = requested.flatMap { lookup.state(for: $0)?.memberIDs ?? [$0] }
            .filter { expandedSeen.insert($0).inserted }
        var denied = Set<ItemID>()
        var retainedPriorRetirements = Set<ItemID>()
        for id in requested {
            if let state = lookup.state(for: id), state.memberIDs.count > 1, !state.isTerminal {
                retainedPriorRetirements.formUnion(state.memberIDs)
            }
            let choice = EpisodeDecisionRecord(episodeID: id, decision: .skip, source: .manual, decidedAt: at)
            let applies = try Self.shouldApplyEpisodeDecision(choice, in: context, lookup: lookup)
            try Self.stageAssociationManualTie(choice, in: context, lookup: lookup)
            if !applies { denied.formUnion(lookup.state(for: id)?.memberIDs ?? [id]) }
        }
        for id in expanded where seen.insert(id).inserted {
            guard !denied.contains(id) else { unresolved.append(id); continue }
            guard let episode = lookup.episodes[id.rawValue],
                  episode.removalKind == nil || (retainedPriorRetirements.contains(id)
                    && episode.removalKind == PodcastEpisodeRemovalKind.retired.rawValue) else { unresolved.append(id); continue }
            let oldListening = listening[id.rawValue]
            let oldDecision = lookup.decisions[id.rawValue]
            let position = queue.firstIndex { $0.episodeID == id.rawValue }
            // Preserve a genuine prior finish and its revision evidence.
            let finishedAt = oldListening?.completedAt ?? at.date
            let nextListening = oldListening ?? ListeningRecord(PodcastListeningState(
                episodeID: id, completedAt: Timestamp(finishedAt), lastRevisionID: nil, updatedAt: at
            ))
            let nextDecision = oldDecision ?? DecisionRecord(
                episodeID: id.rawValue, decision: EpisodeDecision.skip.rawValue,
                source: EpisodeDecisionSource.manual.rawValue, ruleID: nil, decidedAt: at.date
            )
            let priorListening = oldListening.map(CompletionListening.init)
            let priorDecision = oldDecision.map(CompletionDecision.init)
            nextListening.completedAt = finishedAt
            nextListening.updatedAt = at.date
            nextDecision.decision = EpisodeDecision.skip.rawValue
            nextDecision.source = EpisodeDecisionSource.manual.rawValue
            nextDecision.ruleID = nil
            nextDecision.decidedAt = at.date
            members.append(CompletionMember(
                episodeID: id.rawValue, generation: episode.createdAt, feedID: episode.feedID,
                priorListening: priorListening, priorDecision: priorDecision,
                priorRemoval: episode.removalKind, priorRetiredAt: episode.retiredAt,
                postListening: CompletionListening(nextListening), postDecision: CompletionDecision(nextDecision),
                position: position, predecessor: position.flatMap { $0 > 0 ? queue[$0 - 1].episodeID : nil },
                successor: position.flatMap { $0 + 1 < queue.count ? queue[$0 + 1].episodeID : nil },
                addedAt: position.map { queue[$0].addedAt },
                wasCurrent: position.map { queue[$0].position >= Self.podcastCurrentPositionOffset } ?? false,
                capacityReservation: position != nil || priorDecision?.decision == EpisodeDecision.keep.rawValue ? 1 : 0
            ))
            if oldListening == nil { context.insert(nextListening) }
            if oldDecision == nil { context.insert(nextDecision) }
            episode.removalKind = PodcastEpisodeRemovalKind.retired.rawValue
            episode.retiredAt = at.date
        }
        guard !members.isEmpty else {
            if context.hasChanges { try context.save() }
            return PodcastManualCompletionResult(operationID: nil, committed: [], unresolved: unresolved, undoAvailableUntil: nil)
        }
        // One reservation per logical slot, while receipts retain every raw placement.
        var reservedGroups = Set<ItemID>()
        for index in members.indices where members[index].capacityReservation > 0 {
            let id = try ItemID(rawValue: members[index].episodeID)
            let key = lookup.state(for: id)?.representativeID ?? id
            if !reservedGroups.insert(key).inserted { members[index].capacityReservation = 0 }
        }
        let removed = Set(members.map(\.episodeID))
        for row in queue where removed.contains(row.episodeID) { context.delete(row) }
        Self.normalizeCompletionQueue(queue.filter { !removed.contains($0.episodeID) })
        context.insert(ReceiptRecord(operationID: operationID, createdAt: at.date,
            undoAvailableUntil: deadline, members: try JSONEncoder().encode(members)))
        try beforeSave?()
        try context.save()
        return PodcastManualCompletionResult(operationID: operationID,
            committed: members.compactMap { try? ItemID(rawValue: $0.episodeID) },
            unresolved: unresolved, undoAvailableUntil: deadline)
    }

    /// Feed admission uses these durable reservations until Undo expires.
    /// `now` is intentionally not a release condition: overdue capacity remains
    /// reserved until a saved seal. Wall-clock rollback must never unseal it.
    public func manualCompletionCapacityReservations(at now: Date = Date()) throws -> [ItemID: Int] {
        let context = ModelContext(container)
        var capacity: [ItemID: Int] = [:]
        var reserved = Set<ItemID>()
        let sealed = Date.distantPast
        let active = FetchDescriptor<ReceiptRecord>(predicate: #Predicate { $0.undoAvailableUntil != sealed })
        let receipts = try context.fetch(active)
        guard !receipts.isEmpty else { return capacity }
        let lookup = try EpisodeAssociationReadLookup(in: context)
        for receipt in receipts {
            for member in try JSONDecoder().decode([CompletionMember].self, from: receipt.members) where member.reservesCapacity {
                let id = try ItemID(rawValue: member.episodeID)
                let key = lookup.state(for: id)?.representativeID ?? id
                if reserved.insert(key).inserted, let feedID = try? ItemID(rawValue: member.feedID) {
                    capacity[feedID, default: 0] += 1
                }
            }
        }
        return capacity
    }

    /// Unsealed windows survive relaunch; even overdue windows reserve capacity
    /// until sealing has committed. The deadline is reused as the durable seal.
    public func pendingManualCompletionWindows() throws -> [UUID: Date] {
        let context = ModelContext(container)
        let sealed = Date.distantPast
        let active = FetchDescriptor<ReceiptRecord>(predicate: #Predicate { $0.undoAvailableUntil != sealed })
        return Dictionary(try context.fetch(active).map { ($0.operationID, $0.undoAvailableUntil) },
                          uniquingKeysWith: min)
    }

    /// Revisit receipt feeds after restart even when a crash happened between
    /// sealing and admission. Atomic admission makes this replay idempotent.
    public func manualCompletionRecoveryFeedIDs() throws -> Set<ItemID> {
        let context = ModelContext(container)
        var feeds = Set<ItemID>()
        for receipt in try context.fetch(FetchDescriptor<ReceiptRecord>()) {
            let memberFeedIDs: [String]
            if receipt.undoAvailableUntil == .distantPast {
                // Only receipt-owned feeds may trigger admission. Sealed history
                // retains crash-after-seal replay without decoding rollback state.
                guard let members = try? JSONDecoder().decode([CompletionRecoveryFeed].self, from: receipt.members) else { continue }
                memberFeedIDs = members.map(\.feedID)
            } else {
                // Corrupt active proof still fails closed; never release its capacity.
                memberFeedIDs = try JSONDecoder().decode([CompletionMember].self, from: receipt.members).map(\.feedID)
            }
            feeds.formUnion(memberFeedIDs.compactMap { try? ItemID(rawValue: $0) })
        }
        return feeds
    }

    /// Save the seal before a caller releases waiting admissions. Repeated
    /// calls and clock rollback cannot reopen a sealed Undo window.
    public func sealExpiredManualCompletions(at now: Date = Date()) throws -> Set<ItemID> {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        defer { if context.hasChanges { context.rollback() } }
        var feeds = Set<ItemID>()
        let sealed = Date.distantPast
        let expired = FetchDescriptor<ReceiptRecord>(predicate: #Predicate {
            $0.undoAvailableUntil != sealed && $0.undoAvailableUntil <= now
        })
        for receipt in try context.fetch(expired) {
            var members = try JSONDecoder().decode([CompletionMember].self, from: receipt.members)
            for index in members.indices {
                if members[index].reservesCapacity, let id = try? ItemID(rawValue: members[index].feedID) { feeds.insert(id) }
                members[index].capacityReservation = 0
            }
            receipt.members = try JSONEncoder().encode(members)
            receipt.undoAvailableUntil = .distantPast
        }
        if context.hasChanges { try context.save() }
        return feeds
    }

    /// Patches only matching operation-owned state. Newer decisions, listening
    /// changes, dismissals, generations and queue placements win over Undo.
    /// Queue anchors restore relative placement without replacing other edits.
    public func undoManualCompletion(_ operationID: UUID, at: Date = Date()) throws -> PodcastManualCompletionResult {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        defer { if context.hasChanges { context.rollback() } }
        guard let receipt = try context.fetch(FetchDescriptor<ReceiptRecord>()).first(where: {
            $0.operationID == operationID && $0.undoAvailableUntil > at
        }) else {
            return PodcastManualCompletionResult(operationID: operationID, committed: [], unresolved: [], undoAvailableUntil: nil)
        }
        let result = try Self.stageReceiptRestore(receipt, only: nil, explicitRestore: false, at: at, in: context)
        if !result.committed.isEmpty { try context.save() }
        return result
    }

    /// Explicit Restore resolves the newest raw-ID/generation receipt even
    /// after its short Undo window. A conflicting receipt fails closed.
    public func restoreManualCompletion(_ episodeID: ItemID, asOwnerChoice: Bool = true, at: Date? = nil) throws -> Bool? {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        defer { if context.hasChanges { context.rollback() } }
        let choiceAt = try at ?? (asOwnerChoice ? Self.freshLocalOwnerChoiceDate([episodeID], in: context) : Date())
        let result = try Self.stageManualCompletionRestore(episodeID, explicitRestore: asOwnerChoice, at: choiceAt, in: context)
        if result == true { try context.save() }
        return result
    }

    static func stageManualCompletionRestore(
        _ episodeID: ItemID, explicitRestore: Bool = true, at: Date = Date(), in context: ModelContext,
        lookup providedLookup: EpisodeAssociationReadLookup? = nil,
        receiptCandidates: [LocalLibrarySchemaV19Models.ManualCompletionReceiptRecord]? = nil
    ) throws -> Bool? {
        let lookup = try providedLookup ?? EpisodeAssociationReadLookup(in: context)
        if explicitRestore {
            let choice = EpisodeDecisionRecord(episodeID: episodeID, decision: .keep, source: .manual, decidedAt: Timestamp(at))
            let applies = try shouldApplyEpisodeDecision(choice, in: context, lookup: lookup)
            try stageAssociationManualTie(choice, in: context, lookup: lookup)
            guard applies else { return false }
        }
        guard let episode = lookup.episodes[episodeID.rawValue] else { return nil }
        // The frozen schema stores IDs only inside JSON. Materialization still
        // spans receipt history, but only exact-ID candidates need JSON decoding.
        // JSONEncoder preserves escaping, so this cannot miss an encoded raw ID.
        let encodedID = try JSONEncoder().encode(episodeID.rawValue)
        let receipts = try (receiptCandidates ?? context.fetch(FetchDescriptor<ReceiptRecord>())).filter {
            $0.undoAvailableUntil != .distantPast || $0.members.range(of: encodedID) != nil
        }.sorted { $0.createdAt > $1.createdAt }
        for receipt in receipts {
            let members = try JSONDecoder().decode([CompletionMember].self, from: receipt.members)
            guard members.contains(where: { $0.episodeID == episodeID.rawValue && $0.generation == episode.createdAt && !$0.restored }) else { continue }
            guard explicitRestore || receipt.undoAvailableUntil > at else { return false }
            let result = try Self.stageReceiptRestore(receipt, only: episodeID.rawValue, explicitRestore: explicitRestore, at: at, in: context, lookup: lookup)
            return !result.committed.isEmpty
        }
        return nil
    }

    private static func stageReceiptRestore(
        _ receipt: ReceiptRecord, only: String?, explicitRestore: Bool, at: Date, in context: ModelContext,
        lookup providedLookup: EpisodeAssociationReadLookup? = nil
    ) throws -> PodcastManualCompletionResult {
        var members = try JSONDecoder().decode([CompletionMember].self, from: receipt.members)
        let lookup = try providedLookup ?? EpisodeAssociationReadLookup(in: context)
        let episodes = Array(lookup.episodes.values)
        let listening = Array(lookup.listening.values)
        let decisions = Array(lookup.decisions.values)
        var queue = try context.fetch(FetchDescriptor<QueueRecord>()).sorted(by: completionQueuePrecedes)
        var committed: [ItemID] = []
        var unresolved: [ItemID] = []
        let selected = try only.map { rawID in
            let id = try ItemID(rawValue: rawID)
            return Set((lookup.state(for: id)?.memberIDs ?? [id]).map(\.rawValue))
        }
        // One conflicted member blocks its whole logical Undo/Restore, never a partial group.
        var blocked = Set<String>()
        for member in members where !member.restored && (selected == nil || selected!.contains(member.episodeID)) {
            let valid = episodes.contains { $0.id == member.episodeID && $0.createdAt == member.generation
                && $0.feedID == member.feedID && $0.removalKind == PodcastEpisodeRemovalKind.retired.rawValue
                && $0.retiredAt == receipt.createdAt }
                && listening.contains { $0.id == member.episodeID && CompletionListening($0) == member.postListening }
                && decisions.contains { $0.episodeID == member.episodeID && CompletionDecision($0) == member.postDecision }
                && !queue.contains { $0.episodeID == member.episodeID }
            if !valid {
                let id = try ItemID(rawValue: member.episodeID)
                blocked.formUnion((lookup.state(for: id)?.memberIDs ?? [id]).map(\.rawValue))
            }
        }
        for index in members.indices.sorted(by: { (members[$0].position ?? Int.max) < (members[$1].position ?? Int.max) }) {
            let member = members[index]
            guard !member.restored, selected == nil || selected!.contains(member.episodeID),
                  let id = try? ItemID(rawValue: member.episodeID) else { continue }
            guard !blocked.contains(member.episodeID), let episode = episodes.first(where: { $0.id == member.episodeID }),
                  episode.createdAt == member.generation, episode.feedID == member.feedID,
                  episode.removalKind == PodcastEpisodeRemovalKind.retired.rawValue,
                  episode.retiredAt == receipt.createdAt,
                  let currentListening = listening.first(where: { $0.id == member.episodeID }),
                  CompletionListening(currentListening) == member.postListening,
                  let currentDecision = decisions.first(where: { $0.episodeID == member.episodeID }),
                  CompletionDecision(currentDecision) == member.postDecision,
                  !queue.contains(where: { $0.episodeID == member.episodeID }) else {
                unresolved.append(id); continue
            }
            if let prior = member.priorListening {
                currentListening.completedAt = prior.completedAt
                currentListening.lastRevisionID = prior.revision
                currentListening.updatedAt = prior.updatedAt
            } else { context.delete(currentListening) }
            if explicitRestore {
                currentDecision.decision = EpisodeDecision.keep.rawValue
                currentDecision.source = EpisodeDecisionSource.manual.rawValue
                currentDecision.ruleID = nil
                currentDecision.decidedAt = at
            } else if let prior = member.priorDecision {
                currentDecision.decision = prior.decision; currentDecision.source = prior.source
                currentDecision.ruleID = prior.ruleID; currentDecision.decidedAt = prior.decidedAt
            } else { context.delete(currentDecision) }
            episode.removalKind = member.priorRemoval; episode.retiredAt = member.priorRetiredAt
            if let position = member.position, let addedAt = member.addedAt {
                let insertion: Int
                if let next = member.successor, let anchor = queue.firstIndex(where: { $0.episodeID == next }) { insertion = anchor }
                else if let previous = member.predecessor, let anchor = queue.firstIndex(where: { $0.episodeID == previous }) { insertion = anchor + 1 }
                else { insertion = min(position, queue.count) }
                let restoreCurrent = member.wasCurrent && !queue.contains { $0.position >= podcastCurrentPositionOffset }
                let row = QueueRecord(try PodcastQueueEntry(episodeID: id,
                    position: insertion + (restoreCurrent ? podcastCurrentPositionOffset : 0), addedAt: Timestamp(addedAt)))
                context.insert(row); queue.insert(row, at: insertion)
            }
            members[index].restored = true
            committed.append(id)
        }
        if !committed.isEmpty {
            normalizeCompletionQueue(queue)
            receipt.members = try JSONEncoder().encode(members)
        }
        return PodcastManualCompletionResult(operationID: receipt.operationID, committed: committed,
            unresolved: unresolved, undoAvailableUntil: receipt.undoAvailableUntil)
    }

    /// A restored genuine finish must not be mistaken for old stranded EOF
    /// by the bootstrap healer. New EOF writes different listening evidence.
    static func restoredManualCompletionIDs(in context: ModelContext) throws -> Set<String> {
        let live = FetchDescriptor<EpisodeRecord>(predicate: #Predicate { $0.removalKind == nil })
        let completed = FetchDescriptor<ListeningRecord>(predicate: #Predicate { $0.completedAt != nil })
        let episodes = Dictionary(try context.fetch(live).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let listening = Dictionary(try context.fetch(completed).filter { episodes[$0.id] != nil }
            .map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard !listening.isEmpty else { return [] }
        let encodedIDs = try listening.keys.map { try JSONEncoder().encode($0) }
        var restored = Set<String>()
        // No persisted ID index exists in V19. Keep historical proof intact and
        // bound decoding to blobs that can reference a live completed candidate.
        for receipt in try context.fetch(FetchDescriptor<ReceiptRecord>()) {
            guard encodedIDs.contains(where: { receipt.members.range(of: $0) != nil }) else { continue }
            for member in try JSONDecoder().decode([CompletionMember].self, from: receipt.members) where member.restored {
                guard let prior = member.priorListening,
                      let row = listening[member.episodeID], CompletionListening(row) == prior,
                      let episode = episodes[member.episodeID], episode.createdAt == member.generation else { continue }
                restored.insert(member.episodeID)
            }
        }
        return restored
    }

    private static func completionQueuePrecedes(_ lhs: QueueRecord, _ rhs: QueueRecord) -> Bool {
        let first = lhs.position % podcastCurrentPositionOffset
        let second = rhs.position % podcastCurrentPositionOffset
        return first == second ? lhs.episodeID < rhs.episodeID : first < second
    }
    private static func normalizeCompletionQueue(_ queue: [QueueRecord]) {
        for (position, row) in queue.enumerated() {
            row.position = position + (row.position >= podcastCurrentPositionOffset ? podcastCurrentPositionOffset : 0)
        }
    }

    /// Legacy genuine-fact transaction: the supplied listening evidence and
    /// retirement commit together. Queue, decisions and manual receipts are
    /// owned by their separate callers and must not be mutated here.
    @discardableResult
    public func completeAndRetireEpisode(listening: PodcastListeningState, at: Timestamp = Timestamp(Date())) throws -> Bool {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        defer { if context.hasChanges { context.rollback() } }
        let identifier = listening.episodeID.rawValue
        guard let episode = try context.fetch(FetchDescriptor<EpisodeRecord>()).first(where: {
            $0.id == identifier
        }), episode.removalKind == nil else { return false }
        if let existing = try context.fetch(FetchDescriptor<ListeningRecord>()).first(where: { $0.id == identifier }) {
            existing.completedAt = listening.completedAt?.date
            existing.lastRevisionID = listening.lastRevisionID?.rawValue
            existing.updatedAt = listening.updatedAt.date
        } else { context.insert(ListeningRecord(listening)) }
        episode.removalKind = PodcastEpisodeRemovalKind.retired.rawValue
        episode.retiredAt = at.date
        try context.save()
        return true
    }

    @discardableResult
    public func undoCompletedAndRetiredEpisode(_ episodeID: ItemID, updatedAt: Timestamp = Timestamp(Date())) throws -> Bool {
        try restoreManualCompletion(episodeID, asOwnerChoice: false, at: updatedAt.date) ?? false
    }
}
