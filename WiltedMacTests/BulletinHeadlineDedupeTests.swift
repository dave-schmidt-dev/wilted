import Foundation
import WiltedLibrary
import XCTest
@testable import WiltedMac

/// The same story from several news feeds is read once; a clear major update may be read again.
final class BulletinHeadlineDedupeTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func post(_ h: BulletinProducerHarness, _ id: String, _ source: String, _ title: String) -> NewsHeadlineCandidate {
        NewsHeadlineCandidate(id: id, feedTitle: source, title: title, publishedAt: h.now.addingTimeInterval(-60))
    }

    // MARK: Producer

    func testTheSameStoryFromAnotherFeedIsNotReadAgain() async throws {
        let h = BulletinProducerHarness()
        let producer = h.producer()
        await producer.poll()  // baseline
        h.items = [post(h, "npr-1", "NPR", "Magnitude 7.1 earthquake strikes off coast of Japan, tsunami warning issued")]
        await producer.poll()
        XCTAssertEqual(h.published?.headlines.map(\.id), ["headline:npr-1"])

        h.advance(minutes: 40)
        h.items.append(post(h, "bbc-1", "BBC News", "Japan earthquake: tsunami warning issued after magnitude 7.1 quake strikes coast"))
        await producer.poll()
        XCTAssertEqual(h.published?.headlines.map(\.id), ["headline:npr-1"], "BBC's copy of the same story is skipped")
    }

    func testADuplicateDoesNotUseUpTheTurnOfADifferentStory() async throws {
        let h = BulletinProducerHarness()
        let producer = h.producer()
        await producer.poll()
        h.items = [post(h, "npr-1", "NPR", "Senate passes sweeping climate and tax bill after overnight session")]
        await producer.poll()

        h.advance(minutes: 40)
        // The duplicate is the newest post, yet the different story is the one read.
        h.items.append(NewsHeadlineCandidate(id: "ars-1", feedTitle: "Ars Technica",
                                             title: "Researchers demonstrate battery that charges in five minutes",
                                             publishedAt: h.now.addingTimeInterval(-300)))
        h.items.append(post(h, "guardian-1", "The Guardian", "Sweeping climate and tax bill passes Senate after overnight session"))
        await producer.poll()
        XCTAssertEqual(Set(h.published?.headlines.map(\.id) ?? []), ["headline:npr-1", "headline:ars-1"])
    }

    func testAMarkedMajorUpdateIsReadAgain() async throws {
        let h = BulletinProducerHarness()
        let producer = h.producer()
        await producer.poll()
        h.items = [post(h, "npr-1", "NPR", "Magnitude 7.1 earthquake strikes off coast of Japan")]
        await producer.poll()

        h.advance(minutes: 40)
        h.items.append(post(h, "ap-1", "AP", "Update: Japan earthquake death toll rises to 40 as magnitude 7.1 quake strikes coast"))
        await producer.poll()
        XCTAssertEqual(Set(h.published?.headlines.map(\.id) ?? []), ["headline:npr-1", "headline:ap-1"])
    }

    func testAMarkerWithNothingNewIsStillADuplicate() async throws {
        let h = BulletinProducerHarness()
        let producer = h.producer()
        await producer.poll()
        h.items = [post(h, "npr-1", "NPR", "Magnitude 7.1 earthquake strikes off coast of Japan")]
        await producer.poll()

        h.advance(minutes: 40)
        h.items.append(post(h, "bbc-1", "BBC News", "Breaking: magnitude 7.1 earthquake strikes Japan coast"))
        await producer.poll()
        XCTAssertEqual(h.published?.headlines.map(\.id), ["headline:npr-1"])
    }

    func testARestartRemembersTheStoriesTheServerHolds() async throws {
        let h = BulletinProducerHarness()
        let first = h.producer()
        await first.poll()
        h.items = [post(h, "npr-1", "NPR", "Central bank raises interest rates by half a point to fight inflation")]
        await first.poll()

        h.advance(minutes: 40)
        let second = h.producer()
        await second.poll()  // reads the published channel back
        h.items.append(post(h, "bbc-1", "BBC News", "Central bank raises interest rates half point in fight against inflation"))
        await second.poll()
        XCTAssertEqual(h.published?.headlines.map(\.id), ["headline:npr-1"])
    }

    // MARK: Story memory

    func testDifferentStoriesThatShareAFewWordsAreNotMerged() {
        var memory = HeadlineStoryMemory()
        memory.remember("President visits Japan to discuss trade agreement", at: start)
        XCTAssertEqual(memory.verdict(for: "Japan earthquake leaves thousands without power", at: start), .newStory)
    }

    func testAnUnmarkedHeadlineWithMostlyNewContentIsAMajorUpdate() {
        var memory = HeadlineStoryMemory()
        memory.remember("Wildfire forces evacuations near Los Angeles", at: start)
        let later = start.addingTimeInterval(3600)
        XCTAssertEqual(memory.verdict(for: "Los Angeles wildfire evacuations: governor declares emergency, thousands of homes destroyed, firefighters overwhelmed",
                                      at: later), .majorUpdate)
        XCTAssertEqual(memory.verdict(for: "Evacuations ordered as wildfire spreads near Los Angeles", at: later), .duplicate)
    }

    func testAReadUpdateJoinsTheStorySoTheSameUpdateIsNotReadTwice() {
        var memory = HeadlineStoryMemory()
        memory.remember("Magnitude 7.1 earthquake strikes off coast of Japan", at: start)
        let update = "Update: Japan earthquake death toll rises to 40 after magnitude 7.1 quake"
        XCTAssertEqual(memory.verdict(for: update, at: start), .majorUpdate)
        memory.remember(update, at: start)
        XCTAssertEqual(memory.verdict(for: "Latest: death toll from Japan 7.1 earthquake rises to 40", at: start), .duplicate)
    }

    func testAStoryIsForgottenAfterADay() {
        var memory = HeadlineStoryMemory()
        memory.remember("Magnitude 7.1 earthquake strikes off coast of Japan", at: start)
        let title = "Japan coast struck by magnitude 7.1 earthquake"
        XCTAssertEqual(memory.verdict(for: title, at: start.addingTimeInterval(3600)), .duplicate)
        XCTAssertEqual(memory.verdict(for: title, at: start.addingTimeInterval(HeadlineStoryMemory.retention + 60)), .newStory)
    }

    func testKeyWordsIgnoreCaseAccentsPunctuationAndFillerButKeepNumbers() {
        XCTAssertEqual(HeadlineStoryMemory.keyWords(in: "BREAKING: The Café’s 2 owners, in Zürich, say it's over"),
                       ["cafe", "2", "owners", "zurich"])
    }

    func testThePublishedTextLosesItsSourcePrefix() {
        XCTAssertEqual(BulletinProducer.headlineTitle(of: "NPR. Senate passes bill"), "Senate passes bill")
        XCTAssertEqual(BulletinProducer.headlineTitle(of: "Senate passes bill"), "Senate passes bill")
    }
}
