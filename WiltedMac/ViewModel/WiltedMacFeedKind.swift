import Foundation
import WiltedDomain

/// Identifies an article subscription from the same URL-derived ID used by the library.
enum WiltedMacFeedKind {
    static func isArticleFeed(feedID: String, feedURL: URL) -> Bool {
        guard let articleFeedID = try? ItemID.articleFeed(canonicalFeedURL: feedURL) else { return false }
        return articleFeedID.rawValue == feedID
    }

    static func isArticleSubscription(_ subscription: WiltedMacSubscription) -> Bool {
        isArticleFeed(feedID: subscription.id, feedURL: subscription.feedURL)
    }
}
