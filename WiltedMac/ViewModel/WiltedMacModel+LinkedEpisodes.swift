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

extension WiltedMacModel {
    /// Wilted no longer links episodes: a possible duplicate is answered on its own row. A link an
    /// earlier version made still folds its two episodes into one row, so this is the one way left
    /// to undo it. It reverses the association and nothing else.
    func linkedEpisodeAssociation(for episode: WiltedMacEpisode) -> LibraryEpisodeAssociation? {
        episodeAssociations[episode.id].flatMap { $0.isSupported ? $0 : nil }
    }

    /// Prepares the reversal so the owner reads each member's loss before anything changes.
    func prepareLinkedEpisodeUnlink(for episode: WiltedMacEpisode) async -> WiltedMacLinkedEpisodeUnlink? {
        guard let store, let association = linkedEpisodeAssociation(for: episode) else { return nil }
        do {
            let preview = try await store.previewEpisodeAssociationReversal(
                association.groupID, expectedVersion: association.associationVersion
            )
            let titles = Dictionary(
                association.memberIDs.map { id in
                    (id.rawValue, episodes.first { $0.id == id.rawValue }?.title ?? id.rawValue)
                }, uniquingKeysWith: { first, _ in first }
            )
            return WiltedMacLinkedEpisodeUnlink(
                preview: preview, summary: Self.linkedEpisodeUnlinkSummary(for: preview.consequences, titles: titles)
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
