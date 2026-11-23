import Foundation
import WiltedDomain

struct PodcastEpisodeIdentityIndex {
    private struct Entry {
        let episode: PodcastEpisode
        let publishedAt: Date
    }

    private struct FeedEntries {
        var byTitle: [String: [Entry]] = [:]
    }

    private var feeds: [String: FeedEntries] = [:]

    init(_ episodes: [PodcastEpisode]) {
        for episode in episodes {
            let feedID = episode.feedID.rawValue
            let title = PodcastEpisodeIdentityMatcher.normalizedTitle(episode.title)
            if !title.isEmpty, let publishedAt = episode.publishedTime?.date {
                feeds[feedID, default: FeedEntries()].byTitle[title, default: []].append(
                    Entry(episode: episode, publishedAt: publishedAt)
                )
            }
        }
        for (feedID, var feed) in feeds {
            for title in Array(feed.byTitle.keys) {
                feed.byTitle[title]?.sort { $0.publishedAt < $1.publishedAt }
            }
            feeds[feedID] = feed
        }
    }

    /// Compares one feed item with the episodes this index holds, leaving out
    /// any the caller says do not count as an earlier episode.
    func matchMetadata(
        _ incoming: PodcastEpisode,
        excluding isExcluded: (ItemID) -> Bool = { _ in false }
    ) -> PodcastEpisodeIdentityMatcher.Outcome {
        let candidates = nearbyCandidates(for: incoming, in: feeds[incoming.feedID.rawValue])
            .filter { !isExcluded($0.itemID) }
        return PodcastEpisodeIdentityMatcher.match(
            incoming: incoming,
            candidates: candidates,
            normalizedIncomingTitle: PodcastEpisodeIdentityMatcher.normalizedTitle(incoming.title)
        )
    }

    private func nearbyCandidates(
        for incoming: PodcastEpisode,
        in feed: FeedEntries?
    ) -> [PodcastEpisode] {
        guard let feed,
              let publishedAt = incoming.publishedTime?.date else { return [] }
        let title = PodcastEpisodeIdentityMatcher.normalizedTitle(incoming.title)
        guard !title.isEmpty, let entries = feed.byTitle[title] else { return [] }

        let earliest = publishedAt.addingTimeInterval(-60)
        let latest = publishedAt.addingTimeInterval(60)
        var lower = 0
        var upper = entries.count
        while lower < upper {
            let midpoint = lower + (upper - lower) / 2
            if entries[midpoint].publishedAt < earliest {
                lower = midpoint + 1
            } else {
                upper = midpoint
            }
        }

        var nearby: [PodcastEpisode] = []
        var index = lower
        while index < entries.count, entries[index].publishedAt <= latest {
            nearby.append(entries[index].episode)
            index += 1
        }
        return nearby
    }
}
