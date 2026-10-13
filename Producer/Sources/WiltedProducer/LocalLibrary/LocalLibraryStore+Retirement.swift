import Foundation
import SwiftData
import WiltedDomain

extension LocalLibraryStore {
    /// Deletes the revision, download, and artwork records naming the given
    /// episodes' media and returns the URLs they named. One fetch per record
    /// type; the caller commits with one save and only then hands the URLs to
    /// `deleteMediaIfUnreferenced`, so a failed save never deletes audio the
    /// surviving records still name. Dismissal calls it too; unsubscribe reads
    /// the same set through `mediaURLs`, because its staged cascade deletes
    /// these records in separate stages, so every removal reclaims the same
    /// set of files.
    static func deleteMediaRecords(
        forEpisodesWithIDs episodeIDs: Set<String>,
        in context: ModelContext
    ) throws -> [URL] {
        var doomedMedia: [URL] = []
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.RevisionRecord>())
        where episodeIDs.contains(record.itemID) {
            if let value = record.mediaURL, let mediaURL = URL(string: value) { doomedMedia.append(mediaURL) }
            context.delete(record)
        }
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastDownloadRecord>())
        where episodeIDs.contains(record.episodeID) {
            if let value = record.localURL, let mediaURL = URL(string: value) { doomedMedia.append(mediaURL) }
            context.delete(record)
        }
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastArtworkRecord>())
        where episodeIDs.contains(record.ownerID) {
            if let value = record.localURL, let mediaURL = URL(string: value) { doomedMedia.append(mediaURL) }
            context.delete(record)
        }
        return doomedMedia
    }

    /// Returns the named Feed-retired episodes to the feed in `context`
    /// without saving, in one episode-record and one listening-record fetch.
    /// Only a retired row changes: a missing or dismissed one is unresolved
    /// (dismissal is the stronger removal and keeps its own restore pathway),
    /// and one with no removal is already at target. A restored episode's
    /// listening record forgets the revision it last played, which retirement
    /// deleted. `episodeIDs` must be unique; each list keeps their order.
    @discardableResult
    static func stageUnretirement(
        _ episodeIDs: [ItemID],
        in context: ModelContext
    ) throws -> (committed: [ItemID], alreadyAtTarget: [ItemID], unresolved: [ItemID]) {
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV13Models.PodcastEpisodeRecord>())
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        let listening = try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastListeningRecord>())
        let listeningByID = Dictionary(uniqueKeysWithValues: listening.map { ($0.id, $0) })
        let now = Date()
        var committed: [ItemID] = []
        var unresolved: [ItemID] = []
        var alreadyAtTarget: [ItemID] = []
        for id in episodeIDs {
            guard let record = byID[id.rawValue] else { unresolved.append(id); continue }
            if record.removalKind == nil { alreadyAtTarget.append(id); continue }
            guard record.removalKind == PodcastEpisodeRemovalKind.retired.rawValue else { unresolved.append(id); continue }
            record.removalKind = nil; record.retiredAt = nil
            listeningByID[id.rawValue]?.lastRevisionID = nil
            listeningByID[id.rawValue]?.updatedAt = now
            committed.append(id)
        }
        return (committed, alreadyAtTarget, unresolved)
    }
}
