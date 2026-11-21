import Foundation
import WiltedLibrary
import WiltedProducer
import XCTest
@testable import WiltedMac

/// Headlines about skipped topics are never read: sports by default, plus the listener's own words.
final class BulletinHeadlineTopicTests: XCTestCase {
    private let sports = HeadlineTopicFilter(skipSports: true)

    // MARK: Filter

    func testSportsAreRecognisedByTitleCategoryOrSection() {
        XCTAssertTrue(sports.skips(title: "Arsenal go top of the Premier League after late winner"))
        XCTAssertTrue(sports.skips(title: "NFL: Chiefs beat Bills in overtime"))
        XCTAssertTrue(sports.skips(title: "Djokovic through to Wimbledon final"))
        XCTAssertTrue(sports.skips(title: "Late winner settles derby", categories: ["Football"]))
        XCTAssertTrue(sports.skips(title: "Late winner settles derby",
                                   link: URL(string: "https://www.bbc.co.uk/sport/football/123")))
    }

    func testOrdinaryNewsIsNotMistakenForSports() {
        for title in ["Senate passes sweeping climate bill", "Golfo de México storm forces evacuations",
                      "Interest rates held as inflation eases", "Phoenix rises from the ashes of the old mill",
                      "Supporters rally outside parliament"] {
            XCTAssertFalse(sports.skips(title: title, link: URL(string: "https://news.example.test/world/1"),
                                        categories: ["World", "Politics"]), title)
        }
    }

    func testListenerWordsMatchWholeWordsIgnoringCaseAndAccents() {
        let filter = HeadlineTopicFilter(skipSports: false, words: ["Royal family", "café"])
        XCTAssertTrue(filter.skips(title: "ROYAL FAMILY attends ceremony"))
        XCTAssertTrue(filter.skips(title: "New cafe opens downtown"))
        XCTAssertTrue(filter.skips(title: "Ceremony held", categories: ["Royal Family"]))
        XCTAssertFalse(filter.skips(title: "Royal visit to the family farm"), "a phrase needs its words together")
        XCTAssertFalse(filter.skips(title: "Cafeteria prices rise"), "a word matches whole words only")
        XCTAssertFalse(filter.skips(title: "NFL: Chiefs beat Bills"), "sports are not skipped when that is off")
    }

    // MARK: Producer

    func testASportsPostIsNeverReadAndIsCounted() async throws {
        let h = BulletinProducerHarness()
        h.settings.topics = HeadlineTopicFilter(skipSports: true)
        let producer = h.producer()
        await producer.poll()  // baseline
        h.items = [
            NewsHeadlineCandidate(id: "s1", feedTitle: "BBC News", title: "Premier League: Arsenal beat Chelsea",
                                  publishedAt: h.now.addingTimeInterval(-60)),
            NewsHeadlineCandidate(id: "s2", feedTitle: "BBC News", title: "Late winner settles derby",
                                  publishedAt: h.now.addingTimeInterval(-90),
                                  link: URL(string: "https://www.bbc.co.uk/sport/football/1")),
            NewsHeadlineCandidate(id: "n1", feedTitle: "BBC News", title: "Parliament approves new budget",
                                  publishedAt: h.now.addingTimeInterval(-300)),
        ]
        await producer.poll()
        XCTAssertEqual(h.published?.headlines.map(\.id), ["headline:n1"], "the older news post is read, not sport")
        let status = await producer.status
        XCTAssertEqual(status.skippedHeadlineCount, 2)
    }

    func testWithSportsAllowedTheNewestPostIsRead() async throws {
        let h = BulletinProducerHarness()
        let producer = h.producer()
        await producer.poll()
        h.items = [
            NewsHeadlineCandidate(id: "s1", feedTitle: "BBC News", title: "Premier League: Arsenal beat Chelsea",
                                  publishedAt: h.now.addingTimeInterval(-60)),
            NewsHeadlineCandidate(id: "n1", feedTitle: "BBC News", title: "Parliament approves new budget",
                                  publishedAt: h.now.addingTimeInterval(-300)),
        ]
        await producer.poll()
        XCTAssertEqual(h.published?.headlines.map(\.id), ["headline:s1"])
        let status = await producer.status
        XCTAssertEqual(status.skippedHeadlineCount, 0)
    }

    // MARK: Settings

    func testSportsAreSkippedByDefaultIncludingInOlderSavedSettings() throws {
        XCTAssertTrue(WiltedAutomationSettings.defaults.skipSportsHeadlines)
        let legacy = #"{"version":1,"refreshPolicy":{"kind":"manual"},"downloadPolicy":"manual","processingPolicy":{"kind":"immediate"},"transcriptPolicy":"bestAvailable","removeAds":true}"#
        let decoded = try JSONDecoder().decode(WiltedAutomationSettings.self, from: Data(legacy.utf8))
        XCTAssertTrue(decoded.skipSportsHeadlines)
        XCTAssertEqual(decoded.skippedHeadlineWords, [])
    }

    func testListenerWordsAreCleanedAndSurviveSaving() throws {
        let settings = WiltedAutomationSettings.defaults.updatingReports {
            $0.skipSportsHeadlines = false
            $0.skippedHeadlineWords = ["  royals ", "", "Royals", "crypto"]
        }
        XCTAssertEqual(settings.skippedHeadlineWords, ["royals", "crypto"])
        let round = try JSONDecoder().decode(WiltedAutomationSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertFalse(round.skipSportsHeadlines)
        XCTAssertEqual(round.skippedHeadlineWords, ["royals", "crypto"])
    }

    func testTheSkippedCountReadsPlainly() {
        XCTAssertNil(WiltedMacReportsCard.skippedNote(0))
        XCTAssertEqual(WiltedMacReportsCard.skippedNote(1), "1 current headline is skipped by these topics.")
        XCTAssertEqual(WiltedMacReportsCard.skippedNote(4), "4 current headlines are skipped by these topics.")
    }

    // MARK: Feed categories

    func testRSSAndAtomCategoriesAreRead() throws {
        let rss = """
        <rss version="2.0"><channel><title>Wire</title><item><title>Derby</title>
        <link>https://news.example.test/a</link><category>Sport</category><category>Football</category></item>
        </channel></rss>
        """
        let atom = """
        <feed xmlns="http://www.w3.org/2005/Atom"><title>Wire</title><entry><title>Derby</title>
        <link href="https://news.example.test/b"/><category term="Sport"/></entry></feed>
        """
        let feedURL = URL(string: "https://news.example.test/feed")!
        XCTAssertEqual(try ArticleFeedParser.parse(Data(rss.utf8), feedURL: feedURL).items.first?.categories,
                       ["Sport", "Football"])
        XCTAssertEqual(try ArticleFeedParser.parse(Data(atom.utf8), feedURL: feedURL).items.first?.categories, ["Sport"])
    }
}
