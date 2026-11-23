import Foundation
import XCTest
import WiltedDomain
@testable import WiltedMac

/// The Feeds list is grouped into Podcasts, Articles and Headlines (article feeds marked News).
final class WiltedMacFeedSectionTests: XCTestCase {
    private func podcast(_ name: String) -> WiltedMacSubscription {
        let url = URL(string: "https://pods.example.test/\(name).xml")!
        return WiltedMacSubscription(id: "podcast-\(name)", title: name, feedURL: url, episodeCount: 1,
                                     subscribedAt: Date(timeIntervalSince1970: 0), enabled: true)
    }

    private func articleFeed(_ name: String) throws -> WiltedMacSubscription {
        let url = URL(string: "https://news.example.test/\(name).xml")!
        return WiltedMacSubscription(id: try ItemID.articleFeed(canonicalFeedURL: url).rawValue, title: name,
                                     feedURL: url, episodeCount: 0, subscribedAt: Date(timeIntervalSince1970: 0),
                                     enabled: true)
    }

    func testFeedsAreGroupedByKindInListOrder() throws {
        let npr = try articleFeed("npr"), blog = try articleFeed("blog"), bbc = try articleFeed("bbc")
        let show = podcast("show"), other = podcast("other")
        let news: Set<String> = [npr.id, bbc.id]
        let sections = WiltedMacFeedSection.sections([npr, show, blog, bbc, other], isNews: news.contains)
        XCTAssertEqual(sections.map(\.kind), [.podcasts, .articles, .headlines])
        XCTAssertEqual(sections.map { $0.subscriptions.map(\.title) }, [["show", "other"], ["blog"], ["npr", "bbc"]])
        XCTAssertEqual(sections.map(\.kind.title), ["Podcasts", "Articles", "Headline feeds"])
    }

    func testEmptyGroupsAreLeftOut() throws {
        let sections = WiltedMacFeedSection.sections([podcast("show"), try articleFeed("npr")], isNews: { _ in true })
        XCTAssertEqual(sections.map(\.kind), [.podcasts, .headlines])
        XCTAssertTrue(WiltedMacFeedSection.sections([], isNews: { _ in false }).isEmpty)
    }
}
