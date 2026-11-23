import Foundation
import OSLog
import SwiftData
import WiltedDomain

/// One synchronous operation owns this lookup. Model references belong to that
/// operation's context; nothing survives a save or an actor suspension.
struct EpisodeAssociationReadLookup {
    typealias Episode = LocalLibrarySchemaV13Models.PodcastEpisodeRecord
    typealias Decision = LocalLibrarySchemaV16Models.EpisodeDecisionRecord
    typealias Association = LocalLibrarySchemaV20Models.EpisodeAssociationRecord
    let episodes: [String: Episode]
    let decisions: [String: Decision]
    let listening: [String: LocalLibrarySchemaV10Models.PodcastListeningRecord]
    private let recordsByMember: [ItemID: Association]
    let associations: [PodcastEpisodeAssociation]
    let heldPairs: [PodcastEpisodeAssociation]
    let recordedHoldPairs: Set<Set<ItemID>>
    let differentEpisodes: [PodcastEpisodeAssociation]
    let heldEpisodeIDs: Set<ItemID>
    let separatedPairs: Set<Set<ItemID>>
    let duplicateWorkBlockedIDs: Set<ItemID>
    let previouslyHeldIDs: Set<ItemID>
    private let groupsByMember: [ItemID: PodcastEpisodeAssociation]

    init(in context: ModelContext) throws {
        let episodes = Dictionary(try context.fetch(FetchDescriptor<Episode>()).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let decisions = Dictionary(try context.fetch(FetchDescriptor<Decision>()).map { ($0.episodeID, $0) }, uniquingKeysWith: { first, _ in first })
        let listening = Dictionary(try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastListeningRecord>()).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.episodes = episodes
        self.decisions = decisions
        self.listening = listening
        let records = try context.fetch(FetchDescriptor<Association>())
        #if DEBUG
        LocalLibraryStore.associationReadObserver?(4, records.count)
        #endif
        var valid: [(Association, PodcastEpisodeAssociation)] = []
        var inactive: [PodcastEpisodeAssociation] = []
        let decoder = JSONDecoder()
        for record in records {
            do {
                let association = try LocalLibraryStore.decodeAssociation(record)
                let captured = try decoder.decode([AssociationMemberState].self, from: record.capturedMemberState)
                _ = try decoder.decode([Date].self, from: record.manualChoiceConflicts)
                guard captured.count == association.memberIDs.count,
                      Set(captured.map { $0.episode.itemID }) == Set(association.memberIDs),
                      captured.allSatisfy({ member in
                          guard let episode = episodes[member.episode.itemID.rawValue] else { return false }
                          return member.episode.feedID == association.feedID
                              && episode.feedID == association.feedID.rawValue
                              && Self.sameRecordedCreationInstant(episode.createdAt, member.episode.createdAt.date)
                      }) else { throw PodcastEpisodeAssociationError.episodeUnavailable }
                if record.isActive { valid.append((record, association)) }
                else { inactive.append(association) }
            } catch {
                Self.reportInvalid(record.associationID)
            }
        }
        var counts: [ItemID: Int] = [:]
        for (_, association) in valid {
            for member in association.memberIDs { counts[member, default: 0] += 1 }
        }
        valid = valid.filter { record, association in
            guard association.memberIDs.allSatisfy({ counts[$0] == 1 }) else {
                Self.reportInvalid(record.associationID)
                return false
            }
            return true
        }
        associations = valid.map { $0.1 }.sorted { $0.associationID.uuidString < $1.associationID.uuidString }
        let holds = inactive.filter { $0.confirmation.source == .heldForReview }
        recordedHoldPairs = Set(holds.map { Set($0.memberIDs) })
        differentEpisodes = inactive.filter { $0.confirmation.source == .differentEpisodes && $0.reversedAt == nil }
        let separated = Set(inactive.filter {
            $0.confirmation.source == .differentEpisodes ? $0.reversedAt == nil : $0.reversedAt != nil
        }.map { Set($0.memberIDs) })
        separatedPairs = separated
        let grouped = Set(associations.flatMap(\.memberIDs))
        let pending = holds.filter {
            !separated.contains(Set($0.memberIDs))
                && ($0.confirmation.holdsBoth == true ? !Set($0.memberIDs).isSubset(of: grouped) : !grouped.contains($0.confirmation.second))
        }
        heldPairs = pending
        let heldIDs = Set(pending.flatMap { $0.confirmation.holdsBoth == true ? $0.memberIDs : [$0.confirmation.second] })
            .subtracting(grouped)
        heldEpisodeIDs = heldIDs
        let previouslyHeld = Set(holds
            .flatMap { $0.confirmation.holdsBoth == true ? $0.memberIDs : [$0.confirmation.second] })
        previouslyHeldIDs = previouslyHeld
        duplicateWorkBlockedIDs = heldIDs.union(associations.flatMap { group -> [ItemID] in
            guard group.confirmation.source == .feedMatch || group.confirmation.source == .reviewedMatch
                || !previouslyHeld.isDisjoint(with: group.memberIDs) else { return [] }
            return group.memberIDs.filter { $0 != group.representativeID }
        })
        recordsByMember = Dictionary(uniqueKeysWithValues: valid.flatMap { record, association in
            association.memberIDs.map { ($0, record) }
        })
        groupsByMember = Dictionary(uniqueKeysWithValues: valid.flatMap { _, association in
            association.memberIDs.map { ($0, association) }
        })
    }

    /// Captured members use Timestamp's existing ISO8601 precision. Compare
    /// decoded recorded instants, including equivalent Z and .000Z forms.
    /// Submillisecond differences absent from that capture cannot prove a new
    /// source generation; raw ID, feed and membership checks remain exact.
    static func sameRecordedCreationInstant(_ source: Date, _ captured: Date) -> Bool {
        guard let sourceInstant = try? Timestamp(iso8601: Timestamp(source).description),
              let capturedInstant = try? Timestamp(iso8601: Timestamp(captured).description) else { return false }
        return sourceInstant.date == capturedInstant.date
    }

    static func reportInvalid(_ id: UUID) {
        Logger(subsystem: "com.zerodelta.wilted", category: "EpisodeAssociations")
            .warning("Ignoring invalid episode association \(id.uuidString, privacy: .public); retaining raw state")
        #if DEBUG
        LocalLibraryStore.invalidAssociationReadObserver?(id)
        #endif
    }

    func record(for id: ItemID) -> Association? { recordsByMember[id] }

    func state(for id: ItemID) -> PodcastEpisodeLogicalState? {
        guard episodes[id.rawValue] != nil else { return nil }
        guard let group = groupsByMember[id], let record = recordsByMember[id] else {
            return resolve(ids: [id], representativeID: id)
        }
        let state = resolve(ids: group.memberIDs, representativeID: group.representativeID)
        let ties = (try? JSONDecoder().decode([Date].self, from: record.manualChoiceConflicts)) ?? []
        return PodcastEpisodeLogicalState(
            representativeID: state.representativeID, memberIDs: state.memberIDs,
            manualDecision: state.manualDecision, manualDecidedAt: state.manualDecidedAt,
            isTerminal: state.isTerminal,
            hasConflictingManualChoices: state.hasConflictingManualChoices
                || state.manualDecidedAt.map { ties.contains($0.date) } == true
        )
    }

    func resolve(ids: [ItemID], representativeID: ItemID) -> PodcastEpisodeLogicalState {
        let manual = ids.compactMap { decisions[$0.rawValue] }.filter {
            $0.source == EpisodeDecisionSource.manual.rawValue && EpisodeDecision(rawValue: $0.decision) != nil
        }
        let latest = manual.map(\.decidedAt).max()
        let newest = manual.filter { $0.decidedAt == latest }
        let keep = newest.contains { $0.decision == EpisodeDecision.keep.rawValue }
        let skip = newest.contains { $0.decision == EpisodeDecision.skip.rawValue }
        let choice: EpisodeDecision? = keep ? .keep : skip ? .skip : nil
        let completed = ids.compactMap { listening[$0.rawValue]?.completedAt }.max()
        let removed = ids.compactMap { id -> Date? in
            guard let episode = episodes[id.rawValue], episode.removalKind != nil else { return nil }
            return episode.retiredAt
        }.max()
        let terminal = [completed, removed].compactMap { $0 }.max()
        let isTerminal: Bool
        if choice == .keep, let latest { isTerminal = terminal.map { $0 > latest } ?? false }
        else { isTerminal = choice == .skip || terminal != nil }
        return PodcastEpisodeLogicalState(
            representativeID: representativeID, memberIDs: ids, manualDecision: choice,
            manualDecidedAt: latest.map(Timestamp.init), isTerminal: isTerminal,
            hasConflictingManualChoices: (keep && skip) || (keep && terminal != nil && terminal == latest)
        )
    }
}

extension LocalLibraryStore {
    #if DEBUG
    @TaskLocal static var associationReadObserver: (@Sendable (Int, Int) -> Void)?
    @TaskLocal static var invalidAssociationReadObserver: (@Sendable (UUID) -> Void)?
    #endif
}
