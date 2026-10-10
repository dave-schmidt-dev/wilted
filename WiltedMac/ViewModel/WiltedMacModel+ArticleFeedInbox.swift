import Foundation

#if canImport(WiltedProducer)
import WiltedDomain
import WiltedProducer
#endif

/// One post of an article feed waiting in the Feeds inbox for a Keep or Skip.
struct WiltedMacOfferedArticle: Identifiable {
    /// The post's identity inside its feed (the same ID its decision record uses).
    let id: String
    let feedID: String
    let feedTitle: String
    let title: String
    let link: URL
    let publishedAt: Date?
#if canImport(WiltedProducer)
    let item: ArticleFeedItem
#endif
}

extension WiltedMacModel {
#if canImport(WiltedProducer)
    /// Offered posts of feeds still followed, newest first.
    var feedsOfferedArticles: [WiltedMacOfferedArticle] {
        let followed = Set(subscriptions.filter(\.enabled).map(\.id))
        return offeredArticles.filter { followed.contains($0.feedID) }
            .sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
    }

    /// Replaces what `feed` offers with the result of its latest refresh.
    func setOfferedArticles(_ items: [ArticleFeedItem], feed: ArticleFeed) {
        let rows = items.compactMap { item -> WiltedMacOfferedArticle? in
            guard let id = try? item.id(feedURL: feed.canonicalURL) else { return nil }
            return WiltedMacOfferedArticle(
                id: id.rawValue, feedID: feed.itemID.rawValue, feedTitle: feed.title, title: item.title,
                link: item.link, publishedAt: item.publishedAt, item: item
            )
        }
        offeredArticles = offeredArticles.filter { $0.feedID != feed.itemID.rawValue } + rows
    }

    /// Keep: prepares the post behind the shared gate and records the decision. A failed
    /// preparation leaves the post offered, so the reader can try again.
    func keepOfferedArticle(_ offered: WiltedMacOfferedArticle) {
        decideOfferedArticle(offered, keep: true)
    }

    func skipOfferedArticle(_ offered: WiltedMacOfferedArticle) {
        decideOfferedArticle(offered, keep: false)
    }

    private func decideOfferedArticle(_ offered: WiltedMacOfferedArticle, keep: Bool) {
        guard !pendingFeedDecisionIDs.contains(offered.id), !isClosingTemporaryState else { return }
        pendingFeedDecisionIDs.insert(offered.id)
        failedFeedDecisionIDs.remove(offered.id)
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.pendingFeedDecisionIDs.remove(offered.id)
                self.subscriptionWriteTasks[token] = nil
            }
            guard let store = self.store,
                  let feed = try? await store.articleFeed(for: ItemID(rawValue: offered.feedID)) else {
                self.failedFeedDecisionIDs.insert(offered.id); return
            }
            let refresh = ArticleFeedRefresh(store: store, defaults: self.automationSettings.feedAutomationDefaults)
            do {
                if keep {
                    self.podcastOperationMessage = "Preparing \(offered.title)"
                    let done = try await refresh.keep(offered.item, feed: feed) { [weak self] link in
                        guard let self else { throw CancellationError() }
                        return try await self.prepareFeedArticle(link)
                    }
                    guard done else {
                        self.failedFeedDecisionIDs.insert(offered.id)
                        self.podcastOperationMessage = "Could not prepare \(offered.title). Try again."
                        return
                    }
                    self.podcastOperationMessage = "Kept \(offered.title)."
                } else {
                    try await refresh.skip(offered.item, feed: feed)
                    self.podcastOperationMessage = "Skipped \(offered.title)."
                }
                self.offeredArticles.removeAll { $0.id == offered.id }
                if keep, let values = try? await self.loadLibrary(from: store) {
                    self.articles = values.articles
                    self.subscriptions = values.subscriptions
                }
            } catch {
                self.failedFeedDecisionIDs.insert(offered.id)
                self.podcastOperationMessage = "Feed decision could not be saved."
            }
        }
        subscriptionWriteTasks[token] = task
    }
#endif
}
