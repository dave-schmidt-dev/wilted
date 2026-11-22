import Foundation

#if canImport(WiltedProducer)
import WiltedDomain
import WiltedLibrary
import WiltedProducer

/// One reviewed unlink: the store's captured preview and the plain-language
/// consequences shown before the owner confirms.
struct WiltedMacLinkedEpisodeUnlink: Identifiable {
    let preview: PodcastEpisodeAssociationReversalPreview
    let summary: String
    var id: UUID { preview.associationID }
}

/// One earlier link as the owner sees it: the members' names, kept apart even when they share a title.
struct WiltedMacLinkedEpisodePair: Identifiable {
    let association: LibraryEpisodeAssociation
    let labels: [String: String]
    var id: UUID { association.groupID }
    /// The members' names in the order the review lists them.
    var memberLabels: [String] { association.memberIDs.compactMap { labels[$0.rawValue] }.sorted() }
    var title: String { memberLabels.joined(separator: " and ") }
}

extension WiltedMacModel {
    /// Wilted no longer links episodes: a possible duplicate is answered on its own row. A link an
    /// earlier version made still folds its two episodes into one row, so this is the one way left
    /// to undo it. It reverses the association and nothing else.
    func linkedEpisodeAssociation(for episode: WiltedMacEpisode) -> LibraryEpisodeAssociation? {
        episodeAssociations[episode.id].flatMap { $0.isSupported ? $0 : nil }
    }

    /// Every link an earlier version made, whatever state its episodes are in. The Larder folds a
    /// pair into one row and hides a finished one, and Feeds lists only episodes that are not
    /// waiting, so a pair can have no row anywhere: this list is the control that never depends on one.
    var linkedEpisodePairs: [WiltedMacLinkedEpisodePair] {
        var seen = Set<UUID>()
        return episodeAssociations.values
            .filter { $0.isSupported && seen.insert($0.groupID).inserted }
            .map { association in
                WiltedMacLinkedEpisodePair(
                    association: association,
                    labels: Self.linkedEpisodeMemberLabels(for: association.memberIDs, episodes: episodes)
                )
            }
            .sorted { ($0.title, $0.id.uuidString) < ($1.title, $1.id.uuidString) }
    }

    /// One name for each member. Two members that share a title would read the same in the
    /// consequences, so those are told apart by their order and publish date.
    static func linkedEpisodeMemberLabels(for ids: [ItemID], episodes: [WiltedMacEpisode]) -> [String: String] {
        let rows = Dictionary(episodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = ids.sorted {
            let left = rows[$0.rawValue]?.publishedAt ?? .distantPast
            let right = rows[$1.rawValue]?.publishedAt ?? .distantPast
            return left == right ? $0.rawValue < $1.rawValue : left < right
        }
        let titles = ordered.map { rows[$0.rawValue]?.title ?? "An episode no longer in the library" }
        var labels: [String: String] = [:]
        for (index, id) in ordered.enumerated() {
            let shared = titles.indices.filter { titles[$0] == titles[index] }
            guard shared.count > 1 else { labels[id.rawValue] = titles[index]; continue }
            var detail = "\((shared.firstIndex(of: index) ?? 0) + 1) of \(shared.count)"
            if let published = rows[id.rawValue]?.publishedAt {
                detail += ", published \(published.formatted(date: .abbreviated, time: .omitted))"
            }
            labels[id.rawValue] = "\(titles[index]) (\(detail))"
        }
        return labels
    }

    /// Prepares the reversal so the owner reads each member's loss before anything changes.
    func prepareLinkedEpisodeUnlink(for episode: WiltedMacEpisode) async -> WiltedMacLinkedEpisodeUnlink? {
        guard let association = linkedEpisodeAssociation(for: episode) else { return nil }
        return await prepareLinkedEpisodeUnlink(for: association)
    }

    func prepareLinkedEpisodeUnlink(for association: LibraryEpisodeAssociation) async -> WiltedMacLinkedEpisodeUnlink? {
        guard let store else { return nil }
        do {
            let preview = try await store.previewEpisodeAssociationReversal(
                association.groupID, expectedVersion: association.associationVersion
            )
            let labels = Self.linkedEpisodeMemberLabels(for: association.memberIDs, episodes: episodes)
            return WiltedMacLinkedEpisodeUnlink(
                preview: preview, summary: Self.linkedEpisodeUnlinkSummary(for: preview.consequences, titles: labels)
            )
        } catch {
            podcastOperationMessage = "These episodes could not be unlinked. Nothing was changed."
            return nil
        }
    }

    /// Reverses only the reviewed preview. A stale one is refused and nothing changes.
    @discardableResult
    func unlinkEpisodes(_ unlink: WiltedMacLinkedEpisodeUnlink) async -> Bool {
        guard let store else { return false }
        do {
            _ = try await store.reverseEpisodeAssociation(unlink.preview)
        } catch {
            podcastOperationMessage = "The episodes changed since this was reviewed. Nothing was unlinked."
            await reloadLibraryRows()
            return false
        }
        await reloadLibraryRows()
        librarySyncController?.requestPublish()
        podcastOperationMessage = "Episodes unlinked. Each keeps its own progress, decisions and queue slot."
        return true
    }

    /// Names each member that loses inherited Keep or Skip, and warns when later feed automation
    /// may retire an unprotected member and delete its media. No choice is copied.
    static func linkedEpisodeUnlinkSummary(
        for consequences: PodcastEpisodeAssociationReversalConsequences, titles: [String: String] = [:]
    ) -> String {
        func title(_ id: ItemID) -> String { titles[id.rawValue] ?? id.rawValue }
        func choice(_ decision: EpisodeDecision?) -> String {
            decision == .keep ? "Keep" : decision == .skip ? "Skip" : "choice"
        }
        var lines = [
            "Unlinking removes only the link. Every stored episode, its media, progress and queue slot stay exactly as they are.",
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
}
#endif
