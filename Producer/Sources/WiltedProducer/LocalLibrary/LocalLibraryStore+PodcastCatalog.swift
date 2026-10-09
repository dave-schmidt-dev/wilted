import CryptoKit
import Foundation
import SwiftData
import WiltedDomain
import WiltedSync

extension LocalLibraryStore {
    public func save(feed: PodcastFeed) throws {
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV17Models.PodcastFeedRecord>())
        if let existing = records.first(where: { $0.id == feed.itemID.rawValue }) {
            existing.canonicalURL = feed.canonicalURL.absoluteString; existing.title = feed.title
            existing.author = feed.author; existing.artworkURL = feed.artworkURL?.absoluteString; existing.createdAt = feed.createdAt.date
        } else { context.insert(LocalLibrarySchemaV17Models.PodcastFeedRecord(feed)) }
        try context.save()
    }

    public func save(podcastFeed feed: PodcastFeed) throws { try save(feed: feed) }

    public func podcastFeed(for feedID: ItemID) throws -> PodcastFeed? {
        let context = ModelContext(container)
        guard let record = try context.fetch(FetchDescriptor<LocalLibrarySchemaV17Models.PodcastFeedRecord>()).first(where: { $0.id == feedID.rawValue }),
              let canonicalURL = URL(string: record.canonicalURL) else { return nil }
        return try PodcastFeed(itemID: feedID, canonicalURL: canonicalURL, title: record.title,
                               author: record.author, artworkURL: record.artworkURL.flatMap(URL.init), createdAt: Timestamp(record.createdAt))
    }

    public func podcastFeeds() throws -> [PodcastFeed] {
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<LocalLibrarySchemaV17Models.PodcastFeedRecord>()).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }.compactMap { record in
            guard let id = try? ItemID(rawValue: record.id), let url = URL(string: record.canonicalURL) else { return nil }
            return try? PodcastFeed(itemID: id, canonicalURL: url, title: record.title, author: record.author,
                                    artworkURL: record.artworkURL.flatMap(URL.init), createdAt: Timestamp(record.createdAt))
        }
    }

    public func save(episode: PodcastEpisode) throws {
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV13Models.PodcastEpisodeRecord>())
        if let existing = records.first(where: { $0.id == episode.itemID.rawValue }) {
            try Self.apply(episode, to: existing)
        } else { context.insert(try LocalLibrarySchemaV13Models.PodcastEpisodeRecord(episode)) }
        try syncEpisodeLinks([episode], in: context)
        try context.save()
    }

    public func save(podcastEpisode episode: PodcastEpisode) throws { try save(episode: episode) }

    public func podcastEpisode(for episodeID: ItemID) throws -> PodcastEpisode? {
        let context = ModelContext(container)
        guard let record = try context.fetch(FetchDescriptor<LocalLibrarySchemaV13Models.PodcastEpisodeRecord>()).first(where: { $0.id == episodeID.rawValue }),
              let feedID = try? ItemID(rawValue: record.feedID), let feedURL = URL(string: record.feedURL),
              let enclosureURL = URL(string: record.enclosureURL) else { return nil }
        return try PodcastEpisode(itemID: episodeID, feedID: feedID, feedURL: feedURL, rssGUID: record.rssGUID,
                                  title: record.title, author: record.author, publishedTime: record.publishedTime.map(Timestamp.init),
                                  enclosureURL: enclosureURL, enclosureMediaType: record.enclosureMediaType,
                                  enclosureByteCount: record.enclosureByteCount, durationSeconds: record.durationSeconds,
                                  artworkURL: record.artworkURL.flatMap(URL.init),
                                  transcriptSources: try LocalLibrarySchemaV13Models.PodcastEpisodeRecord.decode(record.transcriptSources),
                                  notes: record.notes, episodeLink: try episodeLinks(in: context)[episodeID.rawValue],
                                  createdAt: Timestamp(record.createdAt))
    }

    public func podcastEpisodes(for feedID: ItemID? = nil) throws -> [PodcastEpisode] {
        let context = ModelContext(container)
        let links = try episodeLinks(in: context)
        return try context.fetch(FetchDescriptor<LocalLibrarySchemaV13Models.PodcastEpisodeRecord>())
            .filter { feedID == nil || $0.feedID == feedID!.rawValue }
            .sorted { ($0.publishedTime ?? $0.createdAt) > ($1.publishedTime ?? $1.createdAt) }
            .compactMap { Self.decodePodcastEpisode($0, link: links[$0.id]) }
    }

    static func decodePodcastEpisode(
        _ record: LocalLibrarySchemaV13Models.PodcastEpisodeRecord, link: URL? = nil
    ) -> PodcastEpisode? {
        guard let id = try? ItemID(rawValue: record.id), let fid = try? ItemID(rawValue: record.feedID),
              let feedURL = URL(string: record.feedURL), let enclosureURL = URL(string: record.enclosureURL) else { return nil }
        return try? PodcastEpisode(itemID: id, feedID: fid, feedURL: feedURL, rssGUID: record.rssGUID, title: record.title,
                                   author: record.author, publishedTime: record.publishedTime.map(Timestamp.init), enclosureURL: enclosureURL,
                                   enclosureMediaType: record.enclosureMediaType, enclosureByteCount: record.enclosureByteCount,
                                   durationSeconds: record.durationSeconds, artworkURL: record.artworkURL.flatMap(URL.init),
                                   transcriptSources: (try? LocalLibrarySchemaV13Models.PodcastEpisodeRecord.decode(record.transcriptSources)) ?? [],
                                   notes: record.notes, episodeLink: link, createdAt: Timestamp(record.createdAt))
    }

    public func save(subscription: PodcastSubscription) throws {
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastSubscriptionRecord>())
        if let existing = records.first(where: { $0.feedID == subscription.feedID.rawValue }) {
            existing.subscribedAt = subscription.subscribedAt.date; existing.enabled = subscription.enabled
        } else { context.insert(LocalLibrarySchemaV6Models.PodcastSubscriptionRecord(subscription)) }
        try context.save()
    }

    public func save(feedSubscription subscription: PodcastSubscription) throws { try save(subscription: subscription) }

    public func subscription(for feedID: ItemID) throws -> PodcastSubscription? {
        let context = ModelContext(container)
        guard let record = try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastSubscriptionRecord>()).first(where: { $0.feedID == feedID.rawValue }) else { return nil }
        return PodcastSubscription(feedID: feedID, subscribedAt: Timestamp(record.subscribedAt), enabled: record.enabled)
    }

    public func subscriptions() throws -> [PodcastSubscription] {
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastSubscriptionRecord>()).compactMap { record in
            guard let feedID = try? ItemID(rawValue: record.feedID) else { return nil }
            return PodcastSubscription(feedID: feedID, subscribedAt: Timestamp(record.subscribedAt), enabled: record.enabled)
        }
    }

}
