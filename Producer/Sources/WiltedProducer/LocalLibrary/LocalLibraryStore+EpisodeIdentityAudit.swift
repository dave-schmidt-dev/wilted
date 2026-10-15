import Foundation
import WiltedDomain

extension LocalLibraryStore {
    /// How one targeted episode's identity evidence reads.
    public enum PodcastEpisodeIdentityClassification: String, Equatable, Hashable, Sendable {
        /// The same canonical source ID appears more than once in the targeted
        /// list. Admission keeps the first occurrence and claims it once.
        case repeatedSourceID
        /// The same publisher GUID under a different feed URL. Canonical
        /// identity makes these distinct episodes; only publisher or owner
        /// evidence may confirm a feed move, and the audit never associates
        /// across feeds on its own.
        case feedURLMoveCandidate
        /// Distinct IDs whose title, publication date, and duration all match.
        /// Discovery only: metadata similarity never establishes identity.
        case metadataLookalikeCandidate
        /// Durable evidence about this ID disagrees with itself; see the
        /// entry's `conflicts`.
        case conflictingEvidence
        /// The target names no episode in the store.
        case unmatchedTarget
        /// No duplicate, move, conflict, or lookalike was found.
        case isolated
    }

    /// One piece of identity evidence an audit entry wanted and did not find.
    public enum PodcastEpisodeIdentityProofGap: String, Equatable, Hashable, Sendable {
        /// No publisher page (feed `<link>`) is recorded.
        case publisherPage
        /// No completed download names the original media's content hash.
        case originalMedia
        /// No owner keep/skip decision is recorded.
        case ownerDecision
        /// No durable listening completion or playback progress is recorded.
        case progress
    }

    /// A disagreement inside one episode's durable evidence.
    public enum PodcastEpisodeIdentityConflict: String, CaseIterable, Equatable, Hashable, Sendable {
        /// The durable completion record and the newest playback checkpoints
        /// disagree about whether the episode was completed.
        case completionDisagreesWithPlayback
        /// Distinct targeted episodes carry completed downloads with the same
        /// original content hash. Shared bytes are a candidate for review,
        /// never proof that the two IDs are one episode.
        case sharedOriginalMedia
    }

    /// One dated owner action or durable fact in an episode's chronology.
    public struct PodcastEpisodeIdentityAuditEvent: Equatable, Sendable {
        public enum Kind: String, Equatable, Sendable {
            case keep
            case skip
            case completed
            case retired
            case dismissed
        }

        public let kind: Kind
        /// The decision's origin (`manual`, `rule`, `policy`), when the event
        /// is an owner keep/skip decision.
        public let source: EpisodeDecisionSource?
        public let recordedAt: Timestamp
    }

    /// One targeted episode's evidence bundle.
    ///
    /// The identifying fields -- raw episode and feed IDs, the publisher GUID,
    /// the publisher page, and the original media hash -- are nil in a redacted
    /// report and populated only when the caller asked for them.
    public struct PodcastEpisodeIdentityAuditEntry: Equatable, Sendable {
        /// Position-derived and stable: `episode-1` is the first distinct
        /// target, whatever it is.
        public let reference: String
        public let classifications: [PodcastEpisodeIdentityClassification]
        public let proofGaps: [PodcastEpisodeIdentityProofGap]
        public let conflicts: [PodcastEpisodeIdentityConflict]
        public let chronology: [PodcastEpisodeIdentityAuditEvent]
        public let matched: Bool
        public let episodeID: ItemID?
        public let feedID: ItemID?
        public let rssGUID: String?
        public let publisherPageURL: URL?
        public let originalMediaContentHash: String?
    }

    /// The result of one explicitly targeted identity audit.
    ///
    /// Reports redact identifying values by default: an entry carries a
    /// position reference, classifications, proof gaps, conflicts, and decision
    /// chronology, never a raw ID, GUID, title, or URL, so a report can be
    /// reviewed without handing over library contents. `description` follows
    /// that rule even when the caller asked for the raw values.
    public struct PodcastEpisodeIdentityAuditReport: Equatable, Sendable, CustomStringConvertible {
        public let redactedIdentifyingValues: Bool
        /// Distinct canonical IDs considered.
        public let targetedEpisodeCount: Int
        /// Extra occurrences of a repeated canonical ID.
        public let repeatedSourceIDCount: Int
        /// Targeted IDs that match no episode in the store.
        public let unmatchedCount: Int
        public let entries: [PodcastEpisodeIdentityAuditEntry]

        public var description: String {
            var lines = [
                "Podcast episode identity audit: \(targetedEpisodeCount) targeted, "
                    + "\(repeatedSourceIDCount) repeated source IDs, \(unmatchedCount) unmatched",
            ]
            for entry in entries {
                let classifications = entry.classifications.map(\.rawValue).joined(separator: ",")
                let gaps = entry.proofGaps.map(\.rawValue).joined(separator: ",")
                let conflicts = entry.conflicts.map(\.rawValue).joined(separator: ",")
                lines.append("\(entry.reference): [\(classifications)] gaps=[\(gaps)] conflicts=[\(conflicts)]")
            }
            return lines.joined(separator: "\n")
        }
    }

    /// Audits one explicitly targeted set of episode identities.
    ///
    /// The store form performs exactly one typed `podcastLibrarySnapshot()`
    /// read, so every entry is judged against a consistent instant, and writes
    /// nothing: it saves no record, admits no episode, claims no download, and
    /// leaves the store's contents untouched. The snapshot form audits an
    /// already captured typed snapshot -- the captain's path for a consistent
    /// private clone -- and touches no store at all.
    ///
    /// The call is explicitly targeted: only IDs the caller names are
    /// considered, repeated targets are reported rather than silently dropped,
    /// and no association is ever inferred across feeds. Title, publication
    /// date, and duration only discover candidates for a human to review.
    public func podcastEpisodeIdentityAudit(
        targetedAt episodeIDs: [ItemID],
        redactingIdentifyingValues: Bool = true
    ) throws -> PodcastEpisodeIdentityAuditReport {
        let snapshot = try podcastLibrarySnapshot()
        return Self.podcastEpisodeIdentityAudit(
            targetedAt: episodeIDs, in: snapshot,
            redactingIdentifyingValues: redactingIdentifyingValues
        )
    }

    /// Audits an already captured typed snapshot without touching any store.
    public static func podcastEpisodeIdentityAudit(
        targetedAt episodeIDs: [ItemID],
        in snapshot: PodcastLibrarySnapshot,
        redactingIdentifyingValues: Bool = true
    ) -> PodcastEpisodeIdentityAuditReport {
        var occurrences: [ItemID: Int] = [:]
        var ordered: [ItemID] = []
        for episodeID in episodeIDs {
            let count = (occurrences[episodeID] ?? 0) + 1
            occurrences[episodeID] = count
            if count == 1 { ordered.append(episodeID) }
        }
        let episodesByID = Dictionary(
            snapshot.episodes.map { ($0.itemID, $0) }, uniquingKeysWith: { first, _ in first }
        )

        struct Evidence {
            let episode: PodcastEpisode
            let originalMediaHash: String?
            let hasPlayback: Bool
        }
        var evidenceByID: [ItemID: Evidence] = [:]
        var conflictsByID: [ItemID: Set<PodcastEpisodeIdentityConflict>] = [:]
        var idsByMediaHash: [String: [ItemID]] = [:]
        for episodeID in ordered {
            guard let episode = episodesByID[episodeID] else { continue }
            let download = snapshot.downloads[episodeID]
            let originalMediaHash = download?.status == .completed ? download?.contentHash : nil
            let playbackStates = snapshot.playbackStates.values.filter { $0.itemID == episodeID }
            let listeningCompleted = snapshot.listeningStates[episodeID]?.completedAt != nil
            let playbackCompleted = playbackStates.contains(where: \.completed)
            var conflicts: Set<PodcastEpisodeIdentityConflict> = []
            if !playbackStates.isEmpty, playbackCompleted != listeningCompleted {
                conflicts.insert(.completionDisagreesWithPlayback)
            }
            conflictsByID[episodeID] = conflicts
            if let originalMediaHash { idsByMediaHash[originalMediaHash, default: []].append(episodeID) }
            evidenceByID[episodeID] = Evidence(
                episode: episode, originalMediaHash: originalMediaHash,
                hasPlayback: !playbackStates.isEmpty
            )
        }
        for ids in idsByMediaHash.values where ids.count > 1 {
            for episodeID in ids { conflictsByID[episodeID, default: []].insert(.sharedOriginalMedia) }
        }

        var feedMoveCandidates: Set<ItemID> = []
        var metadataLookalikes: Set<ItemID> = []
        let matched = ordered.filter { evidenceByID[$0] != nil }
        for index in matched.indices {
            for other in matched.indices where other > index {
                guard let left = evidenceByID[matched[index]]?.episode,
                      let right = evidenceByID[matched[other]]?.episode else { continue }
                if left.feedID != right.feedID,
                   let leftGUID = left.rssGUID, let rightGUID = right.rssGUID,
                   leftGUID == rightGUID {
                    feedMoveCandidates.insert(left.itemID)
                    feedMoveCandidates.insert(right.itemID)
                }
                if left.title == right.title,
                   let leftDate = left.publishedTime, let rightDate = right.publishedTime, leftDate == rightDate,
                   let leftDuration = left.durationSeconds, let rightDuration = right.durationSeconds,
                   leftDuration == rightDuration {
                    metadataLookalikes.insert(left.itemID)
                    metadataLookalikes.insert(right.itemID)
                }
            }
        }

        let classificationOrder: [PodcastEpisodeIdentityClassification] = [
            .repeatedSourceID, .feedURLMoveCandidate, .metadataLookalikeCandidate,
            .unmatchedTarget, .conflictingEvidence, .isolated,
        ]
        var entries: [PodcastEpisodeIdentityAuditEntry] = []
        var unmatchedCount = 0
        for (index, episodeID) in ordered.enumerated() {
            let reference = "episode-\(index + 1)"
            guard let evidence = evidenceByID[episodeID] else {
                unmatchedCount += 1
                let repeated = occurrences[episodeID, default: 0] > 1
                entries.append(PodcastEpisodeIdentityAuditEntry(
                    reference: reference,
                    classifications: repeated ? [.repeatedSourceID, .unmatchedTarget] : [.unmatchedTarget],
                    proofGaps: [], conflicts: [], chronology: [], matched: false,
                    episodeID: redactingIdentifyingValues ? nil : episodeID,
                    feedID: nil, rssGUID: nil, publisherPageURL: nil, originalMediaContentHash: nil
                ))
                continue
            }
            let episode = evidence.episode
            var classifications: Set<PodcastEpisodeIdentityClassification> = []
            if occurrences[episodeID, default: 0] > 1 { classifications.insert(.repeatedSourceID) }
            if feedMoveCandidates.contains(episodeID) { classifications.insert(.feedURLMoveCandidate) }
            if metadataLookalikes.contains(episodeID) { classifications.insert(.metadataLookalikeCandidate) }
            let conflicts = conflictsByID[episodeID] ?? []
            if !conflicts.isEmpty { classifications.insert(.conflictingEvidence) }
            if classifications.isEmpty { classifications.insert(.isolated) }
            var gaps: [PodcastEpisodeIdentityProofGap] = []
            if episode.episodeLink == nil { gaps.append(.publisherPage) }
            if evidence.originalMediaHash == nil { gaps.append(.originalMedia) }
            if snapshot.episodeDecisions[episodeID] == nil { gaps.append(.ownerDecision) }
            if snapshot.listeningStates[episodeID] == nil, !evidence.hasPlayback { gaps.append(.progress) }
            entries.append(PodcastEpisodeIdentityAuditEntry(
                reference: reference,
                classifications: classificationOrder.filter(classifications.contains),
                proofGaps: gaps,
                conflicts: PodcastEpisodeIdentityConflict.allCases.filter(conflicts.contains),
                chronology: chronology(for: episodeID, in: snapshot),
                matched: true,
                episodeID: redactingIdentifyingValues ? nil : episodeID,
                feedID: redactingIdentifyingValues ? nil : episode.feedID,
                rssGUID: redactingIdentifyingValues ? nil : episode.rssGUID,
                publisherPageURL: redactingIdentifyingValues ? nil : episode.episodeLink,
                originalMediaContentHash: redactingIdentifyingValues ? nil : evidence.originalMediaHash
            ))
        }
        return PodcastEpisodeIdentityAuditReport(
            redactedIdentifyingValues: redactingIdentifyingValues,
            targetedEpisodeCount: ordered.count,
            repeatedSourceIDCount: episodeIDs.count - ordered.count,
            unmatchedCount: unmatchedCount,
            entries: entries
        )
    }

    /// The dated owner actions and durable facts known about one episode:
    /// its keep/skip decision, its listening completion, and its removal.
    private static func chronology(
        for episodeID: ItemID, in snapshot: PodcastLibrarySnapshot
    ) -> [PodcastEpisodeIdentityAuditEvent] {
        var events: [PodcastEpisodeIdentityAuditEvent] = []
        if let decision = snapshot.episodeDecisions[episodeID] {
            events.append(PodcastEpisodeIdentityAuditEvent(
                kind: decision.decision == .keep ? .keep : .skip,
                source: decision.source,
                recordedAt: decision.decidedAt
            ))
        }
        if let completedAt = snapshot.listeningStates[episodeID]?.completedAt {
            events.append(PodcastEpisodeIdentityAuditEvent(
                kind: .completed, source: nil, recordedAt: completedAt
            ))
        }
        if let retiredAt = snapshot.retiredAtByEpisode[episodeID],
           let removal = snapshot.removalKindByEpisode[episodeID] {
            events.append(PodcastEpisodeIdentityAuditEvent(
                kind: removal == .retired ? .retired : .dismissed, source: nil, recordedAt: retiredAt
            ))
        }
        return events.sorted { left, right in
            left.recordedAt == right.recordedAt
                ? left.kind.rawValue < right.kind.rawValue
                : left.recordedAt < right.recordedAt
        }
    }
}
