import Foundation
import WiltedDomain
import WiltedProducer

/// Captured consequence wording and curated errors for the review sheet.
extension WiltedMacEpisodeIdentityReviewModel {
    /// Item identity, rather than GUID, distinguishes raw copies. If bounded
    /// suffixes collide, show their complete IDs so every label stays unique.
    static func memberLabels(for members: [Candidate]) -> [String: String] {
        let suffixCounts = Dictionary(grouping: members, by: { String($0.id.suffix(6)) })
        return Dictionary(uniqueKeysWithValues: members.map { member in
            let suffix = String(member.id.suffix(6))
            let identity = suffixCounts[suffix, default: []].count > 1 ? member.id : suffix
            var parts = [member.title]
            if let date = member.publishedAt {
                parts.append(date.formatted(date: .abbreviated, time: .shortened))
            }
            parts.append("#\(identity)")
            return (member.id, parts.joined(separator: " \u{00b7} "))
        })
    }

    static func approvalSummary(
        for consequences: PodcastEpisodeAssociationApprovalConsequences?, titles: [String: String] = [:]
    ) -> String {
        guard let consequences else { return "" }
        func title(_ id: ItemID) -> String { titles[id.rawValue] ?? id.rawValue }
        var lines = [
            "Nothing has changed yet. Applying keeps every stored episode, its media and its queue slot.",
        ]
        if consequences.isTerminal {
            lines.append("The pair counts as one finished or suppressed episode, so the Larder does not show that row.")
            lines.append("This pair's state keeps feed refreshes from re-adding its episodes and refuses an automatic download that has not started yet (only these duplicate-group rules are evaluated; every other download condition is unchanged).")
        } else if consequences.isLarderRowVisible {
            lines.append("The Larder will show one row for the pair, named \(title(consequences.representativeID)).")
            lines.append("The pair stays active, so the Larder shows that row even if one stored copy was retired or dismissed.")
            lines.append("This pair's state does not block feed refreshes and does not refuse an automatic download that has not started yet (only these duplicate-group rules are evaluated; every other download condition is unchanged).")
        } else {
            lines.append("The pair stays active, but every stored copy was retired or dismissed, so the Larder shows no row.")
            lines.append("This pair's state does not block feed refreshes and does not refuse an automatic download that has not started yet (only these duplicate-group rules are evaluated; every other download condition is unchanged).")
        }
        if let decision = consequences.winningDecision {
            lines.append(decision == .keep
                ? "The pair's newest manual choice is Keep: the group stays protected from automatic Skip rules."
                : "The pair's newest manual choice is Skip: the group stays suppressed.")
        } else {
            lines.append("Neither copy has a manual Keep or Skip; feed automation keeps deciding as it does today.")
        }
        if consequences.hasConflictingManualChoices {
            lines.append("The copies' manual choices conflict, so Keep is preserved and shown.")
        }
        for member in consequences.members {
            let name = title(member.episodeID)
            var facts: [String] = []
            facts.append(member.retainsRawRow ? "stored copy kept" : "stored copy was retired or dismissed")
            if member.hasDownloadRecord {
                facts.append("has a download record")
            } else if member.canClaimDownload {
                facts.append("no download record, and the duplicate-group rule does not refuse a new automatic download")
            } else {
                facts.append("no download record, and the duplicate-group rule refuses a new automatic download")
            }
            if let position = member.queuePosition {
                facts.append(member.isQueueCurrent ? "holds queue slot \(position) and is current" : "holds queue slot \(position)")
            } else {
                facts.append("no queue slot")
            }
            lines.append("\(name): \(facts.joined(separator: ", ")).")
        }
        return lines.joined(separator: " ")
    }

    /// The reversal text names each member losing inherited Keep/suppression
    /// or a newer resolved choice, and warns that later feed automation may
    /// retire an unprotected member and delete its media. No choice is copied.
    static func reversalSummary(
        for consequences: PodcastEpisodeAssociationReversalConsequences?, titles: [String: String] = [:]
    ) -> String {
        guard let consequences else { return "" }
        func title(_ id: ItemID) -> String { titles[id.rawValue] ?? id.rawValue }
        func choice(_ decision: EpisodeDecision?) -> String {
            decision == .keep ? "Keep" : decision == .skip ? "Skip" : "choice"
        }
        var lines = [
            "Reversing removes only the association. Every stored episode, its media, progress and queue slot stay exactly as they are.",
        ]
        for member in consequences.members {
            let name = title(member.episodeID)
            if member.losesNewerResolvedOverride {
                lines.append("\(name) keeps its own earlier \(choice(member.ownManualDecision)); the pair's newer \(choice(member.resolvedManualDecision)) no longer applies, and its own choice still shields it from automatic rules.")
            } else if member.losesInheritedProtection {
                lines.append("\(name) has no Keep of its own and loses the pair's inherited protection. Later feed automation may retire it and delete its unprotected media.")
            } else if member.losesInheritedSuppression {
                lines.append("\(name) has no Skip of its own; it stops inheriting the pair's suppression.")
            } else if member.ownManualDecision != nil {
                lines.append("\(name) keeps its own manual choice.")
            } else {
                lines.append("\(name) has no manual choice to inherit.")
            }
        }
        return lines.joined(separator: " ")
    }

    // MARK: - Errors

    static func isStale(_ error: Error) -> Bool {
        guard let associationError = error as? PodcastEpisodeAssociationError else { return false }
        switch associationError {
        case .stalePreview, .staleVersion, .conflictingOwnerState, .overlappingAssociation:
            return true
        default:
            return false
        }
    }

    static func message(for error: Error) -> String {
        guard let associationError = error as? PodcastEpisodeAssociationError else {
            return "The review could not be completed. Nothing was changed."
        }
        switch associationError {
        case .invalidPair:
            return "Those two entries are not a valid pair."
        case .crossFeed:
            return "The two episodes belong to different shows."
        case .episodeUnavailable:
            return "One of the episodes is no longer in the library."
        case .overlappingAssociation:
            return "One of the episodes already belongs to an active association."
        case .stalePreview, .staleVersion, .conflictingOwnerState:
            return staleReviewMessage
        case .confirmationAlreadyUsed:
            return "This confirmation was already used. Review the pair again."
        case .corruptAssociation:
            return "A stored association could not be read; nothing was changed."
        }
    }
}
