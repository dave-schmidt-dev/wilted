import CryptoKit
import Foundation
import SwiftData
import WiltedDomain
import WiltedSync

extension LocalLibraryStore {
    /// One episode the listener removed, and when.
    public struct PodcastEpisodeDismissal: Equatable, Sendable {
        public let episodeID: ItemID
        public let feedID: ItemID?
        public let title: String?
        public let dismissedAt: Timestamp
    }

    /// Marks one episode dismissed and reclaims its per-revision artifacts.
    ///
    /// The row itself survives, carrying `removalKind = .dismissed` --
    /// `restoreEpisode` is what reverses this, the same store operation that
    /// reverses `retireEpisode`. Deleting the row used to be the other half
    /// of dismissal, paired with a tombstone in a standalone table so the
    /// next refresh would not silently re-admit what was just removed; the
    /// state column makes that unnecessary, because a row a refresh already
    /// sees as "existing" is left alone regardless of its removal state.
    ///
    /// The queue, download, speed, artwork, revision, and transcript records
    /// still go -- dismissal keeps reclaiming those artifacts, only the state
    /// representation changed. The preparation journal stays, so the Removed
    /// list can still say a preparation happened for this episode, and
    /// restoring should not resurrect a finished cut with no revision or
    /// transcript behind it. Downloaded media stays on disk for the reason
    /// `unsubscribeFromPodcast` gives: a `RevisionID` is derived from
    /// content, so two episodes with identical bytes share one audio
    /// revision and deleting the file here could break an episode that
    /// survives this call.
    ///
    /// Idempotent against a second dismissal, which keeps the first
    /// dismissal's timestamp and returns false. Dismissing an episode that
    /// is currently retired is allowed and overwrites the retirement --
    /// dismissal was always the stronger of the two removals.
    @discardableResult
    public func dismissPodcastEpisode(_ episodeID: ItemID, at dismissedAt: Timestamp = Timestamp(Date())) throws -> Bool {
        let context = ModelContext(container)
        let identifier = episodeID.rawValue
        let existing = try context.fetch(FetchDescriptor<LocalLibrarySchemaV13Models.PodcastEpisodeRecord>())
            .first(where: { $0.id == identifier })
        guard let episode = existing else {
            // No row for this id at all -- a legacy or never-admitted episode.
            // Dismissal must still stick, the same way it did when a separate
            // tombstone table could record a removal with no matching row.
            context.insert(LocalLibrarySchemaV13Models.PodcastEpisodeRecord(
                placeholderForDismissalID: identifier, feedID: nil, title: nil, dismissedAt: dismissedAt.date
            ))
            try context.save()
            return true
        }
        guard episode.removalKind != PodcastEpisodeRemovalKind.dismissed.rawValue else { return false }
        episode.removalKind = PodcastEpisodeRemovalKind.dismissed.rawValue
        episode.retiredAt = dismissedAt.date
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastQueueRecord>())
        where record.episodeID == identifier { context.delete(record) }
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastDownloadRecord>())
        where record.episodeID == identifier { context.delete(record) }
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastPlaybackSpeedRecord>())
        where record.itemID == identifier { context.delete(record) }
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastArtworkRecord>())
        where record.ownerID == identifier { context.delete(record) }
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.RevisionRecord>())
        where record.itemID == identifier { context.delete(record) }
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV7Models.TranscriptRecord>())
        where record.itemID == identifier { context.delete(record) }
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.PlaybackRecord>())
        where record.itemID == identifier { context.delete(record) }
        try context.save()
        return true
    }

    /// Every episode currently dismissed, newest removal first.
    public func dismissedPodcastEpisodes() throws -> [PodcastEpisodeDismissal] {
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<LocalLibrarySchemaV13Models.PodcastEpisodeRecord>())
            .filter { $0.removalKind == PodcastEpisodeRemovalKind.dismissed.rawValue }
            .sorted { ($0.retiredAt ?? $0.createdAt) > ($1.retiredAt ?? $1.createdAt) }
            .compactMap { record in
                guard let episodeID = try? ItemID(rawValue: record.id) else { return nil }
                return PodcastEpisodeDismissal(
                    episodeID: episodeID,
                    feedID: try? ItemID(rawValue: record.feedID),
                    title: record.title,
                    dismissedAt: Timestamp(record.retiredAt ?? record.createdAt)
                )
            }
    }

    /// Removes a subscription and every record Wilted stored on its behalf.
    ///
    /// Records only. Downloaded media files stay on disk because revision-aware
    /// reclamation is a separate job; unsubscribe does not guess whether a
    /// namespaced or same-item legacy revision is still referenced.
    @discardableResult
    public func unsubscribeFromPodcast(feedID: ItemID) throws -> Int {
        let context = ModelContext(container)
        let feed = feedID.rawValue
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastSubscriptionRecord>())
        where record.feedID == feed { context.delete(record) }
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastFeedRecord>())
        where record.id == feed { context.delete(record) }

        let episodes = try context.fetch(FetchDescriptor<LocalLibrarySchemaV13Models.PodcastEpisodeRecord>())
            .filter { $0.feedID == feed }
        let episodeIDs = Set(episodes.map(\.id))
        for record in episodes { context.delete(record) }
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastQueueRecord>())
        where episodeIDs.contains(record.episodeID) { context.delete(record) }
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastDownloadRecord>())
        where episodeIDs.contains(record.episodeID) { context.delete(record) }
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastPlaybackSpeedRecord>())
        where episodeIDs.contains(record.itemID) { context.delete(record) }
        // Artwork is owned by the feed as well as by its episodes.
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastArtworkRecord>())
        where episodeIDs.contains(record.ownerID) || record.ownerID == feed { context.delete(record) }
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.RevisionRecord>())
        where episodeIDs.contains(record.itemID) { context.delete(record) }
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV7Models.TranscriptRecord>())
        where episodeIDs.contains(record.itemID) { context.delete(record) }
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.PlaybackRecord>())
        where episodeIDs.contains(record.itemID) { context.delete(record) }
        // A dismissal is now a state on the episode row itself, deleted with
        // it above, so resubscribing starts clean rather than inheriting a
        // blocklist the listener can no longer see anywhere -- no separate
        // tombstone table to sweep here any more.
        try context.save()
        return episodeIDs.count
    }

    static func apply(
        _ episode: PodcastEpisode,
        to record: LocalLibrarySchemaV13Models.PodcastEpisodeRecord
    ) throws {
        record.feedID = episode.feedID.rawValue
        record.feedURL = episode.feedURL.absoluteString
        record.rssGUID = episode.rssGUID
        record.title = episode.title
        record.author = episode.author
        record.publishedTime = episode.publishedTime?.date
        record.enclosureURL = episode.enclosureURL.absoluteString
        record.enclosureMediaType = episode.enclosureMediaType
        record.enclosureByteCount = episode.enclosureByteCount
        record.durationSeconds = episode.durationSeconds
        record.artworkURL = episode.artworkURL?.absoluteString
        record.transcriptSources = try LocalLibrarySchemaV13Models.PodcastEpisodeRecord.encode(episode.transcriptSources)
        record.notes = episode.notes
        record.createdAt = episode.createdAt.date
    }

}
