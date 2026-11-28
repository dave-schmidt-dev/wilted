import Foundation
import WiltedProducer

/// Current posts from followed feeds marked Headlines only.
struct NewsHeadlineSupply: Equatable, Sendable {
    let feeds: [ArticleFeed]
    /// Recognized sports sources omitted before any network request.
    let excludedSportsFeedIDs: Set<String>
    let candidates: [NewsHeadlineCandidate]
}

struct NewsHeadlineFeedSelection: Equatable, Sendable {
    let feeds: [ArticleFeed]
    let excludedSportsFeedIDs: Set<String>
}

/// Shares feed eligibility and loading between the bulletin hub, readiness, and morning report.
enum NewsHeadlineCandidateReader {
    /// The bulletin hub historically reads at most the newest fifty posts per feed.
    static let maximumCandidatesPerFeed = 50

    static func headlineFeeds(
        in store: LocalLibraryStore, topics: HeadlineTopicFilter? = nil
    ) async throws -> [ArticleFeed] {
        let selection = try await selectHeadlineFeeds(in: store, topics: topics)
        return selection.feeds
    }

    static func selectHeadlineFeeds(
        in store: LocalLibraryStore, topics: HeadlineTopicFilter? = nil
    ) async throws -> NewsHeadlineFeedSelection {
        let subscriptions = try await store.subscriptions()
        let followedFeedIDs = Set(subscriptions.map(\.feedID))
        let catalogFeeds = try await store.articleFeeds()
        var feeds: [ArticleFeed] = []
        for feed in catalogFeeds where followedFeedIDs.contains(feed.itemID) {
            guard try await store.isNews(feedID: feed.itemID) else { continue }
            feeds.append(feed)
        }
        guard topics?.skipSports == true else {
            return NewsHeadlineFeedSelection(feeds: feeds, excludedSportsFeedIDs: [])
        }
        let excluded = feeds.filter {
            HeadlineTopicFilter.isRecognizableSportsSource(title: $0.title, url: $0.canonicalURL)
        }
        let excludedIDs = Set(excluded.map { $0.itemID.rawValue })
        return NewsHeadlineFeedSelection(
            feeds: feeds.filter { !excludedIDs.contains($0.itemID.rawValue) },
            excludedSportsFeedIDs: excludedIDs)
    }

    static func read(
        in store: LocalLibraryStore,
        using client: PodcastFeedClient,
        topics: HeadlineTopicFilter? = nil
    ) async throws -> NewsHeadlineSupply {
        let selection = try await selectHeadlineFeeds(in: store, topics: topics)
        let feeds = selection.feeds
        var candidates: [NewsHeadlineCandidate] = []
        var failed = 0
        var lastFailure: Error?
        for feed in feeds {
            try Task.checkCancellation()
            do {
                let document = try await client.loadArticleFeed(feed.canonicalURL)
                for item in document.items.prefix(maximumCandidatesPerFeed) {
                    guard let id = try? item.id(feedURL: feed.canonicalURL) else { continue }
                    candidates.append(NewsHeadlineCandidate(
                        id: id.rawValue, feedTitle: feed.title, feedID: feed.itemID.rawValue,
                        title: item.title, publishedAt: item.publishedAt,
                        link: item.link, categories: item.categories))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                failed += 1
                lastFailure = error
            }
        }
        if !feeds.isEmpty, failed == feeds.count, let lastFailure { throw lastFailure }
        return NewsHeadlineSupply(
            feeds: feeds, excludedSportsFeedIDs: selection.excludedSportsFeedIDs, candidates: candidates)
    }
}
