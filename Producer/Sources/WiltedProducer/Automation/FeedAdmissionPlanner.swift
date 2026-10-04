import Foundation

/// An episode that automation may admit to a feed's kept set.
public struct FeedAdmissionCandidate: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let releaseDate: Date

    public init(id: String, releaseDate: Date) {
        self.id = id
        self.releaseDate = releaseDate
    }
}

/// A listener's explicit choice for an episode.
public enum FeedManualDecision: String, Codable, Equatable, Hashable, Sendable {
    case keep
    case skip
}

/// The only actions the admission planner may propose.
public enum FeedAdmissionOutcome: String, Codable, Equatable, Hashable, Sendable {
    case keepNow
    case wait
    case leaveUndecided
}

/// An automatic admission decision for one candidate.
public struct FeedAdmissionDecision: Codable, Equatable, Hashable, Sendable {
    public let candidate: FeedAdmissionCandidate
    public let outcome: FeedAdmissionOutcome

    public init(candidate: FeedAdmissionCandidate, outcome: FeedAdmissionOutcome) {
        self.candidate = candidate
        self.outcome = outcome
    }
}

/// Computes additions only; it cannot express removal of an already-kept episode.
public enum FeedAdmissionPlanner {
    /// Plans automatic admissions in FIFO release order. Candidates with a
    /// manual decision, a playing/part-heard ID, or an ID already kept are
    /// intentionally omitted so automation cannot touch them.
    public static func plan(
        candidates: [FeedAdmissionCandidate],
        keptEpisodeIDs: Set<String>,
        playingEpisodeID: String?,
        partHeardEpisodeIDs: Set<String>,
        manualDecisions: [String: FeedManualDecision],
        policy: EffectiveFeedAutomationPolicy
    ) -> [FeedAdmissionDecision] {
        let protectedIDs = partHeardEpisodeIDs.union(playingEpisodeID.map { [$0] } ?? [])
        let automaticCandidates = candidates
            .filter { candidate in
                !keptEpisodeIDs.contains(candidate.id)
                    && !protectedIDs.contains(candidate.id)
                    && manualDecisions[candidate.id] == nil
            }
            .sorted(by: fifoOrder)

        guard policy.autoKeep else {
            return automaticCandidates.map { FeedAdmissionDecision(candidate: $0, outcome: .leaveUndecided) }
        }

        guard let keptLimit = policy.keptLimit else {
            return automaticCandidates.map { FeedAdmissionDecision(candidate: $0, outcome: .keepNow) }
        }

        let availableSlots = max(0, keptLimit - keptEpisodeIDs.count)
        return automaticCandidates.enumerated().map { index, candidate in
            FeedAdmissionDecision(
                candidate: candidate,
                outcome: index < availableSlots ? .keepNow : .wait
            )
        }
    }

    private static func fifoOrder(_ lhs: FeedAdmissionCandidate, _ rhs: FeedAdmissionCandidate) -> Bool {
        if lhs.releaseDate != rhs.releaseDate {
            return lhs.releaseDate < rhs.releaseDate
        }
        return lhs.id < rhs.id
    }
}
