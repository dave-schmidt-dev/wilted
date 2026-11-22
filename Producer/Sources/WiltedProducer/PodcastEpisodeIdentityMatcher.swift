import Foundation
import WiltedDomain

/// Conservative evidence for reconciling a feed item's changed source identity.
enum PodcastEpisodeIdentityMatcher {
    enum PairOutcome: Sendable {
        case none
        case match
    }

    enum AmbiguityReason: String, Equatable, Hashable, Sendable {
        case multipleMatches
    }

    enum Outcome: Equatable, Sendable {
        case none
        case matched(ItemID)
        case ambiguous(candidateIDs: [ItemID], reasons: Set<AmbiguityReason>)
    }

    /// Compares one publisher item with already known episodes from any
    /// lifecycle state. A URL is never inspected as identity evidence.
    static func match(
        incoming: PodcastEpisode,
        candidates: [PodcastEpisode]
    ) -> Outcome {
        let incomingTitle = normalizedTitle(incoming.title)
        return match(
            incoming: incoming, candidates: candidates,
            normalizedIncomingTitle: incomingTitle
        ) { normalizedTitle($0.title) }
    }

    /// Optimized entry for a title-index bucket whose candidates already share
    /// the supplied normalized title.
    static func match(
        incoming: PodcastEpisode,
        candidates: [PodcastEpisode],
        normalizedIncomingTitle: String
    ) -> Outcome {
        match(
            incoming: incoming, candidates: candidates,
            normalizedIncomingTitle: normalizedIncomingTitle
        ) { _ in normalizedIncomingTitle }
    }

    private static func match(
        incoming: PodcastEpisode,
        candidates: [PodcastEpisode],
        normalizedIncomingTitle: String,
        normalizedCandidateTitle: (PodcastEpisode) -> String
    ) -> Outcome {
        var exactMatches: Set<ItemID> = []
        guard !normalizedIncomingTitle.isEmpty else { return .none }

        for candidate in candidates where candidate.feedID == incoming.feedID {
            guard candidate.itemID != incoming.itemID else { continue }
            switch matchPair(
                incoming: incoming, candidate: candidate,
                normalizedIncomingTitle: normalizedIncomingTitle,
                normalizedCandidateTitle: normalizedCandidateTitle(candidate)
            ) {
            case .none:
                continue
            case .match:
                exactMatches.insert(candidate.itemID)
            }
        }

        guard !exactMatches.isEmpty else { return .none }
        guard exactMatches.count == 1, let match = exactMatches.first else {
            return .ambiguous(
                candidateIDs: exactMatches.sorted { $0.rawValue < $1.rawValue },
                reasons: [.multipleMatches]
            )
        }
        return .matched(match)
    }

    /// Evaluates one pair using titles a caller may have normalized while
    /// building a feed-wide index.
    static func matchPair(
        incoming: PodcastEpisode,
        candidate: PodcastEpisode,
        normalizedIncomingTitle: String,
        normalizedCandidateTitle: String
    ) -> PairOutcome {
        guard incoming.feedID == candidate.feedID,
              incoming.itemID != candidate.itemID,
              !normalizedIncomingTitle.isEmpty,
              normalizedIncomingTitle == normalizedCandidateTitle,
              let incomingDate = incoming.publishedTime?.date,
              let candidateDate = candidate.publishedTime?.date,
              abs(candidateDate.timeIntervalSince(incomingDate)) <= 60 else {
            return .none
        }

        switch (incoming.durationSeconds, candidate.durationSeconds) {
        case let (incomingDuration?, candidateDuration?):
            // Lengths further apart than a few seconds are different episodes
            // that happen to share a title and a publish minute.
            return abs(incomingDuration - candidateDuration) <= 5 ? .match : .none
        case (nil, nil):
            guard let incomingBytes = incoming.enclosureByteCount,
                  let candidateBytes = candidate.enclosureByteCount,
                  incomingBytes == candidateBytes else {
                return .none
            }
            return .match
        case (.some, nil), (nil, .some):
            return .none
        }
    }

    /// Normalizes Unicode, case, and whitespace while preserving punctuation.
    static func normalizedTitle(_ title: String) -> String {
        let normalized = title
            .precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
        return normalized.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
