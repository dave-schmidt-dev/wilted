import Foundation
import SwiftData
import WiltedDomain

/// One feed's title and timing evidence, shared by admission and review.
public struct PodcastDuplicateMatch: Sendable {
    static let publicationWindow: TimeInterval = 60
    public let publicationDifference: TimeInterval?
    public let durationDifference: TimeInterval?
    public var isClear: Bool { publicationDifference != nil && durationDifference.map { $0 <= 5 } == true }

    public init?(_ first: PodcastEpisode, _ second: PodcastEpisode) {
        guard first.feedID == second.feedID, first.itemID != second.itemID,
              first.title == second.title else { return nil }
        publicationDifference = first.publishedTime.flatMap { firstDate in
            second.publishedTime.map { abs(firstDate.date.timeIntervalSince($0.date)) }
        }
        durationDifference = first.durationSeconds.flatMap { length in
            second.durationSeconds.map { abs(length - $0) }
        }
        if let publicationDifference, publicationDifference > Self.publicationWindow { return nil }
        if publicationDifference == nil, let durationDifference, durationDifference > 5 { return nil }
    }

    public func isCloser(than other: Self) -> Bool {
        if isClear != other.isClear { return isClear }
        let date = publicationDifference ?? .infinity
        let otherDate = other.publicationDifference ?? .infinity
        if date != otherDate { return date < otherDate }
        return (durationDifference ?? .infinity) < (other.durationDifference ?? .infinity)
    }
}

extension LocalLibraryStore {
    /// Scans the refreshed shows, including older stored copies that have
    /// disappeared from RSS. Every pair disposition shares the admission save.
    func reconcileFeedDuplicates(
        feedIDs: Set<ItemID>, admitted: [PodcastEpisode], existing: Set<String>, at: Timestamp, in context: ModelContext
    ) throws -> (blocked: Set<ItemID>, released: Set<ItemID>) {
        let lookup = try EpisodeAssociationReadLookup(in: context)
        var blocked = lookup.duplicateWorkBlockedIDs
        let feeds = Set(feedIDs.map(\.rawValue))
        let records = lookup.episodes.values.filter { feeds.contains($0.feedID) }
        let publisherOrder = Dictionary(uniqueKeysWithValues: admitted.enumerated().map { ($1.itemID, $0) })
        let grouped = Set(lookup.associations.flatMap(\.memberIDs))
        let recorded = lookup.separatedPairs.union(lookup.associations.map { Set($0.memberIDs) })
            .union(lookup.recordedHoldPairs)
        var snapshot: PodcastLibrarySnapshot?
        for show in Dictionary(grouping: records, by: \.feedID).values {
            for sameTitle in Dictionary(grouping: show, by: \.title).values where sameTitle.count > 1 {
                let episodes = sameTitle.compactMap { Self.decodePodcastEpisode($0) }
                let pairs = Self.undecidedPairs(episodes, lookup: lookup, recorded: recorded, existing: existing)
                guard let firstPair = pairs.first else { continue }
                let library = try snapshot ?? podcastLibrarySnapshot(profile: .publication, in: context)
                snapshot = library
                let ids = Set(pairs.flatMap { [$0.first.itemID, $0.second.itemID] })
                let states = try Self.associationMemberStates(Array(ids), feedID: firstPair.first.feedID, in: library)
                let byID = Dictionary(uniqueKeysWithValues: states.map { ($0.episode.itemID, $0) })
                for pair in pairs {
                    guard let first = byID[pair.first.itemID], let second = byID[pair.second.itemID] else {
                        throw PodcastEpisodeAssociationError.episodeUnavailable
                    }
                    let ordered = [first, second].sorted {
                        $0.precedesAsOriginal($1, existing: existing, grouped: grouped, publisherOrder: publisherOrder)
                    }
                    let original = ordered[0].episode, copy = ordered[1].episode
                    guard !grouped.contains(copy.itemID) else { continue }
                    let clear = pair.clear && !grouped.contains(original.itemID)
                        && !(ordered[0].hasListenerHistory && ordered[1].hasListenerHistory)
                    var evidence = PodcastEpisodePairConfirmation(
                        confirmationID: UUID(), feedID: original.feedID, first: original.itemID,
                        second: copy.itemID, confirmedAt: at)
                    evidence.source = clear ? .feedMatch : .heldForReview
                    if !clear && !existing.contains(original.itemID.rawValue) {
                        evidence.holdsBoth = true
                        blocked.insert(original.itemID)
                    }
                    _ = try Self.stageEpisodePair(evidence, representativeID: original.itemID,
                                                  capturedMembers: JSONEncoder().encode(ordered), at: at, in: context)
                    blocked.insert(copy.itemID)
                }
            }
        }
        let released = lookup.previouslyHeldIDs.subtracting(blocked).filter {
            lookup.episodes[$0.rawValue]?.removalKind == nil && lookup.decisions[$0.rawValue] == nil
                && lookup.state(for: $0)?.isTerminal == false
        }
        return (blocked, released)
    }

    /// Count every plausible neighbour before deciding any pair. Two incumbents
    /// competing for the same incoming copy remain untouched while it waits.
    private static func undecidedPairs(
        _ episodes: [PodcastEpisode], lookup: EpisodeAssociationReadLookup, recorded: Set<Set<ItemID>>, existing: Set<String>
    ) -> [(first: PodcastEpisode, second: PodcastEpisode, clear: Bool)] {
        var neighbours: [ItemID: Set<ItemID>] = [:]
        var pairs: [(PodcastEpisode, PodcastEpisode, Bool)] = []
        let sorted = episodes.sorted { ($0.publishedTime?.date ?? .distantPast) < ($1.publishedTime?.date ?? .distantPast) }
        for (index, left) in sorted.enumerated() {
            for right in sorted.dropFirst(index + 1) {
                if let start = left.publishedTime, let end = right.publishedTime,
                   end.date.timeIntervalSince(start.date) > PodcastDuplicateMatch.publicationWindow { break }
                let ids: Set<ItemID> = [left.itemID, right.itemID]
                guard !lookup.separatedPairs.contains(ids), let match = PodcastDuplicateMatch(left, right) else { continue }
                neighbours[left.itemID, default: []].insert(right.itemID)
                neighbours[right.itemID, default: []].insert(left.itemID)
                if !recorded.contains(ids) { pairs.append((left, right, match.isClear)) }
            }
        }
        return pairs.compactMap { left, right, clear in
            let lhs = neighbours[left.itemID, default: []], rhs = neighbours[right.itemID, default: []]
            if existing.contains(left.itemID.rawValue), existing.contains(right.itemID.rawValue),
               lhs.intersection(rhs).contains(where: { !existing.contains($0.rawValue) || lookup.heldEpisodeIDs.contains($0) }) {
                return nil
            }
            return (left, right, clear && lhs.count == 1 && rhs.count == 1)
        }
    }

    /// An independent ticket writer or interrupted transfer can race a feed
    /// read. Only shows with pair history need a validated membership read.
    static func requireDuplicateWorkEligibility(_ kind: WorkTicketKind, subjectID: String, in context: ModelContext) throws {
        guard kind == .podcastDownload || kind == .podcastPreparation else { return }
        var episodeQuery = FetchDescriptor<EpisodeAssociationReadLookup.Episode>(predicate: #Predicate { $0.id == subjectID })
        episodeQuery.fetchLimit = 1
        guard let feedID = try context.fetch(episodeQuery).first?.feedID else { return }
        var pairs = FetchDescriptor<EpisodeAssociationReadLookup.Association>(predicate: #Predicate { $0.feedID == feedID })
        pairs.fetchLimit = 1
        guard try context.fetchCount(pairs) > 0 else { return }
        let id = try ItemID(rawValue: subjectID)
        guard try !EpisodeAssociationReadLookup(in: context).duplicateWorkBlockedIDs.contains(id) else {
            throw AutomaticEpisodeAdmissionError.episodeUnavailable
        }
    }

    public func episodeReviewPairs(for id: ItemID) throws -> (
        held: [PodcastEpisodeAssociation], excluded: Set<ItemID>, lastSeparateDecision: UUID?
    ) {
        let lookup = try EpisodeAssociationReadLookup(in: ModelContext(container))
        let lastSeparate = lookup.differentEpisodes.filter { $0.memberIDs.contains(id) }.max {
            $0.createdAt == $1.createdAt ? $0.associationID.uuidString < $1.associationID.uuidString : $0.createdAt < $1.createdAt
        }
        return (lookup.heldPairs.filter { $0.memberIDs.contains(id) },
                Set(lookup.separatedPairs.filter { $0.contains(id) }.flatMap { $0 }.filter { $0 != id }),
                lastSeparate?.associationID)
    }

    /// An explicit negative decision is also pair-specific history. It never
    /// briefly activates the association or copies an episode's state.
    public func keepEpisodesSeparate(_ comparison: PodcastEpisodeAssociationComparison, at: Timestamp) throws -> UUID {
        let ids = [comparison.first.episodeID, comparison.second.episodeID]
        guard try podcastEpisodeAssociationComparison(first: ids[0], second: ids[1]) == comparison else { throw PodcastEpisodeAssociationError.stalePreview }
        let context = ModelContext(container)
        let lookup = try EpisodeAssociationReadLookup(in: context)
        guard !lookup.associations.contains(where: { Set($0.memberIDs) == Set(ids) }) else {
            throw PodcastEpisodeAssociationError.overlappingAssociation
        }
        guard !lookup.separatedPairs.contains(Set(ids)) else { throw PodcastEpisodeAssociationError.stalePreview }
        let snapshot = try podcastLibrarySnapshot(profile: .publication)
        let members = try Self.associationMemberStates(ids, feedID: comparison.feedID, in: snapshot)
        var evidence = PodcastEpisodePairConfirmation(confirmationID: UUID(), feedID: comparison.feedID,
                                                     first: ids[0], second: ids[1], confirmedAt: at)
        evidence.source = .differentEpisodes
        let record = try Self.stageEpisodePair(evidence, representativeID: ids[0],
                                      capturedMembers: JSONEncoder().encode(members), at: at, in: context)
        try context.save()
        return record.associationID
    }

    public func undoSeparateEpisodes(_ id: UUID, at: Timestamp) throws {
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV20Models.EpisodeAssociationRecord>())
        guard let record = records.first(where: { $0.associationID == id }), record.reversedAt == nil,
              try Self.decodeAssociation(record).confirmation.source == .differentEpisodes else {
            throw PodcastEpisodeAssociationError.stalePreview
        }
        record.reversedAt = at.date
        record.version += 1
        try context.save()
    }
}

private extension AssociationMemberState {
    func precedesAsOriginal(_ other: Self, existing: Set<String>, grouped: Set<ItemID>, publisherOrder: [ItemID: Int]) -> Bool {
        let lhs = episode.itemID, rhs = other.episode.itemID
        if grouped.contains(lhs) != grouped.contains(rhs) { return grouped.contains(lhs) }
        if existing.contains(lhs.rawValue) != existing.contains(rhs.rawValue) { return existing.contains(lhs.rawValue) }
        if hasListenerHistory != other.hasListenerHistory { return hasListenerHistory }
        if (queuePosition != nil) != (other.queuePosition != nil) { return queuePosition != nil }
        if (download != nil) != (other.download != nil) { return download != nil }
        if episode.createdAt != other.episode.createdAt { return episode.createdAt < other.episode.createdAt }
        let left = publisherOrder[lhs] ?? .max, right = publisherOrder[rhs] ?? .max
        return left == right ? lhs.rawValue < rhs.rawValue : left < right
    }

    var hasListenerHistory: Bool {
        removal != nil || listening?.completedAt != nil || playback.contains { $0.completed || $0.positionSeconds > 0 }
            || decision?.source == .manual || isCurrent
    }
}
