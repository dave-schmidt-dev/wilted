import Foundation
import SwiftData
import WiltedDomain

private typealias LinkRecord = LocalLibrarySchemaV15Models.PodcastEpisodeLinkRecord

extension LocalLibraryStore {
    /// Makes the link row mirror `episode.episodeLink`: written or refreshed
    /// when the feed publishes one, removed when it no longer does. Stages in
    /// `context`; the caller saves, so the link commits with the episode row.
    func syncEpisodeLinks(_ episodes: [PodcastEpisode], in context: ModelContext) throws {
        guard !episodes.isEmpty else { return }
        var byID: [String: LinkRecord] = [:]
        for record in try context.fetch(FetchDescriptor<LinkRecord>()) where byID[record.itemID] == nil {
            byID[record.itemID] = record
        }
        let now = Date()
        for episode in episodes {
            let identifier = episode.itemID.rawValue
            if let link = episode.episodeLink?.absoluteString {
                if let record = byID[identifier] {
                    if record.url != link { record.url = link; record.updatedAt = now }
                } else {
                    let record = LinkRecord(itemID: identifier, url: link, updatedAt: now)
                    context.insert(record)
                    byID[identifier] = record
                }
            } else if let record = byID[identifier] {
                context.delete(record)
                byID[identifier] = nil
            }
        }
    }

    /// Every stored episode link, keyed by episode `itemID`.
    func episodeLinks(in context: ModelContext) throws -> [String: URL] {
        var links: [String: URL] = [:]
        for record in try context.fetch(FetchDescriptor<LinkRecord>()) {
            if let url = URL(string: record.url) { links[record.itemID] = url }
        }
        return links
    }

    /// Stages deletion of the link rows for `episodeIDs`; returns how many.
    func stageEpisodeLinkRemoval(for episodeIDs: Set<String>, in context: ModelContext) throws -> Int {
        var removed = 0
        for record in try context.fetch(FetchDescriptor<LinkRecord>()) where episodeIDs.contains(record.itemID) {
            context.delete(record)
            removed += 1
        }
        return removed
    }
}
