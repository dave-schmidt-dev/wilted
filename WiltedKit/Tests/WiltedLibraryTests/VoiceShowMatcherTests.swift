import Foundation
import XCTest
@testable import WiltedLibrary

final class VoiceShowMatcherTests: XCTestCase {
    // MARK: - Normalization Tests

    func testNormalizeLowercasesAndStripsAccentsAndPunctuation() {
        XCTAssertEqual(VoiceShowMatcher.normalize("Café Society!"), "cafe society")
        XCTAssertEqual(VoiceShowMatcher.normalize("cafe society"), "cafe society")
    }

    func testNormalizeDropsLeadingArticle() {
        XCTAssertEqual(VoiceShowMatcher.normalize("The Daily"), "daily")
        XCTAssertEqual(VoiceShowMatcher.normalize("the daily"), "daily")
        XCTAssertEqual(VoiceShowMatcher.normalize("Daily"), "daily")
    }

    func testNormalizePreservesNonLeadingArticleAndWordsStartingWithThe() {
        XCTAssertEqual(VoiceShowMatcher.normalize("Theater of the Mind"), "theater of the mind")
        XCTAssertEqual(VoiceShowMatcher.normalize("Into the Wild"), "into the wild")
    }

    func testNormalizeCollapsesSpaces() {
        XCTAssertEqual(VoiceShowMatcher.normalize("  The   Tech   Crunch   "), "tech crunch")
        XCTAssertEqual(VoiceShowMatcher.normalize(""), "")
        XCTAssertEqual(VoiceShowMatcher.normalize("   "), "")
    }

    // MARK: - Match Tier Tests

    func testMatchEqualNormalizedSpacesRemoved() {
        // "tech crunch daily" vs "TechCrunch Daily"
        let result = VoiceShowMatcher.match("tech crunch daily", among: ["TechCrunch Daily"])
        XCTAssertEqual(result, .match("TechCrunch Daily"))
    }

    func testMatchContainsTier() {
        // "techcrunch daily" vs "TechCrunch Daily Crunch" (contains tier)
        let result = VoiceShowMatcher.match("techcrunch daily", among: ["TechCrunch Daily Crunch"])
        XCTAssertEqual(result, .match("TechCrunch Daily Crunch"))

        // Reverse containment: spoken contains title
        let reverseResult = VoiceShowMatcher.match("TechCrunch Daily Crunch", among: ["TechCrunch Daily"])
        XCTAssertEqual(reverseResult, .match("TechCrunch Daily"))

        // Shorter side under 4 letters does not qualify for contains tier
        let shortResult = VoiceShowMatcher.match("car", among: ["Scary Stories"])
        XCTAssertEqual(shortResult, .none)

        // Four letters inside a longer word never qualify: only whole-word runs do
        let fourLetterResult = VoiceShowMatcher.match("scar", among: ["Scary Stories"])
        XCTAssertEqual(fourLetterResult, .none)

        // Four letters that are a whole word of the title do
        XCTAssertEqual(VoiceShowMatcher.match("scary", among: ["Scary Stories"]), .match("Scary Stories"))
    }

    func testMatchLeadingArticleDrop() {
        // "the daily" vs "Daily"
        let result = VoiceShowMatcher.match("the daily", among: ["Daily"])
        XCTAssertEqual(result, .match("Daily"))

        let reverse = VoiceShowMatcher.match("daily", among: ["The Daily"])
        XCTAssertEqual(reverse, .match("The Daily"))
    }

    func testMatchPunctuationAndAccents() {
        // "Café Society!" vs "cafe society"
        let result = VoiceShowMatcher.match("cafe society", among: ["Café Society!"])
        XCTAssertEqual(result, .match("Café Society!"))

        let spokenWithPunct = VoiceShowMatcher.match("Café Society!", among: ["cafe society"])
        XCTAssertEqual(spokenWithPunct, .match("cafe society"))
    }

    func testMatchWordSubsetTier() {
        // Spoken words are subset of title words, but title does not contain spoken as space-free substring
        let result = VoiceShowMatcher.match("planet school", among: ["Planet Money Summer School"])
        XCTAssertEqual(result, .match("Planet Money Summer School"))

        let dailyNewsResult = VoiceShowMatcher.match("daily show", among: ["The Daily News Show"])
        XCTAssertEqual(dailyNewsResult, .match("The Daily News Show"))
    }

    func testMatchFuzzyTier() {
        // "tech crunch dailey" vs "TechCrunch Daily"
        let result = VoiceShowMatcher.match("tech crunch dailey", among: ["TechCrunch Daily"])
        XCTAssertEqual(result, .match("TechCrunch Daily"))
    }

    func testMatchNoMatch() {
        let result = VoiceShowMatcher.match("xyz", among: ["TechCrunch Daily"])
        XCTAssertEqual(result, .none)

        let emptyTitles = VoiceShowMatcher.match("TechCrunch", among: [])
        XCTAssertEqual(emptyTitles, .none)
    }

    func testMatchAmbiguousWhenTwoDistinctTitlesTie() {
        let result = VoiceShowMatcher.match("techcrunch", among: ["TechCrunch Daily", "TechCrunch Weekly"])
        XCTAssertEqual(result, .ambiguous(["TechCrunch Daily", "TechCrunch Weekly"]))
    }

    func testMatchDuplicateTitlesCountOnce() {
        // Identical duplicate titles
        let identical = VoiceShowMatcher.match("tech crunch daily", among: ["TechCrunch Daily", "TechCrunch Daily"])
        XCTAssertEqual(identical, .match("TechCrunch Daily"))

        // Titles that differ only in case are the same feed
        let caseDuplicates = VoiceShowMatcher.match(
            "tech crunch daily", among: ["TechCrunch Daily", "techcrunch daily"])
        XCTAssertEqual(caseDuplicates, .match("TechCrunch Daily"))

        // Titles that differ beyond case are distinct feeds, so the match is ambiguous
        let distinct = VoiceShowMatcher.match(
            "tech crunch daily", among: ["TechCrunch Daily", "The TechCrunch Daily!"])
        XCTAssertEqual(distinct, .ambiguous(["TechCrunch Daily", "The TechCrunch Daily!"]))
    }

    func testMatchEmptySpokenNameIsNone() {
        XCTAssertEqual(VoiceShowMatcher.match("", among: ["TechCrunch Daily"]), .none)
        XCTAssertEqual(VoiceShowMatcher.match("   ", among: ["TechCrunch Daily"]), .none)
        XCTAssertEqual(VoiceShowMatcher.match("The", among: ["TechCrunch Daily"]), .none)
        XCTAssertEqual(VoiceShowMatcher.match("!!!", among: ["TechCrunch Daily"]), .none)
    }

    func testAWordInsideAnotherWordNeverMatches() {
        XCTAssertEqual(VoiceShowMatcher.match("Science", among: ["Conscience"]), .none)
    }

    func testFeedsThatNormalizeAlikeStaySeparate() {
        let titles = ["The Daily", "Daily"]
        XCTAssertEqual(VoiceShowMatcher.match("The Daily", among: titles), .match("The Daily"))
        XCTAssertEqual(VoiceShowMatcher.match("daily", among: titles), .match("Daily"))
    }
}

