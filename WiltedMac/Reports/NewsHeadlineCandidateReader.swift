import Foundation
import WiltedProducer

/// Current posts from followed feeds marked Headlines only.
struct NewsHeadlineSupply: Equatable, Sendable {
    let feeds: [ArticleFeed]
    let candidates: [NewsHeadlineCandidate]
}

/// Shares feed eligibility and loading between the bulletin hub, readiness, and morning report.
enum NewsHeadlineCandidateReader {
    /// The bulletin hub historically reads at most the newest fifty posts per feed.
    static let maximumCandidatesPerFeed = 50

    static func headlineFeeds(in store: LocalLibraryStore) async throws -> [ArticleFeed] {
        let subscriptions = try await store.subscriptions()
        let followedFeedIDs = Set(subscriptions.map(\.feedID))
        let catalogFeeds = try await store.articleFeeds()
        var feeds: [ArticleFeed] = []
        for feed in catalogFeeds where followedFeedIDs.contains(feed.itemID) {
            guard try await store.isNews(feedID: feed.itemID) else { continue }
            feeds.append(feed)
        }
        return feeds
    }

    static func read(in store: LocalLibraryStore, using client: PodcastFeedClient) async throws -> NewsHeadlineSupply {
        let feeds = try await headlineFeeds(in: store)
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
                        id: id.rawValue, feedTitle: feed.title, title: item.title, publishedAt: item.publishedAt,
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
        return NewsHeadlineSupply(feeds: feeds, candidates: candidates)
    }
}
