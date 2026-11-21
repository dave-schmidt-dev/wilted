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

/// One group of the Feeds list: podcasts, article feeds, or article feeds marked News (headline sources).
struct WiltedMacFeedSection: Identifiable, Equatable {
    enum Kind: String, CaseIterable {
        case podcasts, articles, headlines

        var title: String {
            switch self {
            case .podcasts: "Podcasts"
            case .articles: "Articles"
            case .headlines: "Headlines"
            }
        }
    }

    let kind: Kind
    let subscriptions: [WiltedMacSubscription]
    var id: String { kind.rawValue }

    /// The feeds grouped in list order; a group with no feed is left out.
    static func sections(_ subscriptions: [WiltedMacSubscription],
                         isNews: (String) -> Bool) -> [WiltedMacFeedSection] {
        let grouped = Dictionary(grouping: subscriptions) { subscription -> Kind in
            guard WiltedMacFeedKind.isArticleSubscription(subscription) else { return .podcasts }
            return isNews(subscription.id) ? .headlines : .articles
        }
        return Kind.allCases.compactMap { kind in
            guard let members = grouped[kind], !members.isEmpty else { return nil }
            return WiltedMacFeedSection(kind: kind, subscriptions: members)
        }
    }
}
