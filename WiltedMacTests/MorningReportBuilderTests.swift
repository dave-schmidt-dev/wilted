import AVFoundation
import Foundation
import XCTest
import WiltedDomain
@testable import WiltedProducer
@testable import WiltedMac

private struct PlainFailure: Error {}

/// Builder behaviour with an injected M4A renderer, a stub forecast and stub headlines.
@MainActor
final class MorningReportBuilderTests: XCTestCase {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var texts: [String] = []
        func record(_ text: String) -> Int { lock.lock(); defer { lock.unlock() }; texts.append(text); return texts.count }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return texts }
    }

    private final class VoiceCalls: @unchecked Sendable {
        private let lock = NSLock()
        private var voices: [ApprovedReadingVoiceID] = []
        func record(_ voice: ApprovedReadingVoiceID) { lock.lock(); defer { lock.unlock() }; voices.append(voice) }
        var all: [ApprovedReadingVoiceID] { lock.lock(); defer { lock.unlock() }; return voices }
    }

    /// Produces a local M4A of `seconds(callNumber)` duration for each test render.
    private func voiceRenderer(
        _ calls: Calls, seconds: @escaping @Sendable (Int) -> Double = { _ in 2 }
    ) -> MorningReportBuilder.VoiceRenderer {
        { text, voiceID, outputURL in
            let duration = seconds(calls.record(text))
            let sampleRate = duration > 30 ? 8_000 : 24_000
            let sampleCount = Int(duration * Double(sampleRate))
            let samples = (0..<sampleCount).map { Float(0.3 * sin(2 * Double.pi * 330 * Double($0) / Double(sampleRate))) }
            let actualDuration = try MorningReportAudio.write(samples: samples, sampleRate: sampleRate, to: outputURL)
            return ArticleNarrationAudio(
                audioURL: outputURL, duration: actualDuration,
                voiceRevision: ArticleNarrationCoordinator.shortTextVoiceRevision(for: voiceID))
        }
    }

    private let periods = [
        MorningReportForecastPeriod(name: "Today", text: "Sunny with a high near 72."),
        MorningReportForecastPeriod(name: "Tonight", text: "Clear with a low around 50."),
    ]

    private func headlines(_ count: Int, words: Int = 4) -> MorningReportHeadlines {
        MorningReportHeadlines(hasNewsFeeds: true, titles: (1...count).map { index in
            (["Headline\(index)"] + Array(repeating: "word", count: max(0, words - 1))).joined(separator: " ")
        })
    }

    private func makeStore() throws -> (LocalLibraryStore, URL) {
        let directory = wiltedTemporaryDirectory("morning-report")
        return (try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite")), directory)
    }

    private func builder(
        _ store: LocalLibraryStore, _ calls: Calls, news: MorningReportHeadlines, located: Bool = true,
        seconds: @escaping @Sendable (Int) -> Double = { _ in 2 }
    ) -> MorningReportBuilder {
        let periods = self.periods
        return MorningReportBuilder(
            store: store, voiceID: .caseyKasem, renderVoice: voiceRenderer(calls, seconds: seconds),
            coordinates: { located ? (35.0, -80.0) : nil }, forecast: { _, _ in periods },
            headlines: { _, _ in news }, calendar: Calendar(identifier: .gregorian))
    }

    private func headlineCount(_ text: String) -> Int { text.components(separatedBy: "Headline").count - 1 }

    private func assertPlain(_ reason: String) {
        XCTAssertFalse(reason.contains("Error Domain"), reason)
        XCTAssertFalse(reason.contains("SECRET-TOKEN"), reason)
    }

    func testTenHeadlinesYieldAScriptEstimatedUnder300Seconds() async throws {
        let (store, _) = try makeStore()
        let calls = Calls()
        // 10 headlines of 160 words: five would be about 320 s with the forecast, so some must be trimmed.
        let outcome = await builder(store, calls, news: headlines(10, words: 160)).build(now: Date(timeIntervalSince1970: 1_800_000_000))
        guard case let .published(_, _, _, count, _) = outcome else { return XCTFail("expected a report, got \(outcome)") }
        let text = try XCTUnwrap(calls.all.first)
        XCTAssertLessThan(MorningReportBuilder.estimatedSeconds(text), 300)
        XCTAssertLessThanOrEqual(headlineCount(text), 5)
        XCTAssertLessThan(headlineCount(text), 5, "an over-long script is trimmed")
        XCTAssertEqual(count, headlineCount(text))
        XCTAssertEqual(calls.all.count, 1)
    }

    func testSelectedVoiceRendersAndIdentifiesTheSavedReport() async throws {
        let (store, _) = try makeStore()
        let selectedVoices = VoiceCalls()
        let periods = self.periods
        let builder = MorningReportBuilder(
            store: store, voiceID: .caseyKasem,
            renderVoice: { _, voiceID, outputURL in
                selectedVoices.record(voiceID)
                let samples = (0..<48_000).map { Float(0.3 * sin(2 * Double.pi * 330 * Double($0) / 24_000)) }
                let duration = try MorningReportAudio.write(samples: samples, sampleRate: 24_000, to: outputURL)
                return ArticleNarrationAudio(
                    audioURL: outputURL, duration: duration,
                    voiceRevision: ArticleNarrationCoordinator.shortTextVoiceRevision(for: voiceID))
            },
            coordinates: { (35.0, -80.0) }, forecast: { _, _ in periods },
            headlines: { _, _ in MorningReportHeadlines(hasNewsFeeds: true, titles: ["A headline"])
            }, calendar: Calendar(identifier: .gregorian))

        let outcome = await builder.build(now: Date(timeIntervalSince1970: 1_800_000_000))

        guard case let .published(itemID, _, duration, _, _) = outcome else {
            return XCTFail("expected a report, got \(outcome)")
        }
        XCTAssertEqual(selectedVoices.all, [.caseyKasem])
        XCTAssertEqual(duration, 2, accuracy: 0.1)
        let firstIsSaved = try await store.hasMorningReport(itemID)
        XCTAssertTrue(firstIsSaved)

        let secondBuilder = MorningReportBuilder(
            store: store, voiceID: .rodSerling,
            renderVoice: { _, voiceID, outputURL in
                selectedVoices.record(voiceID)
                let samples = (0..<48_000).map { Float(0.3 * sin(2 * Double.pi * 330 * Double($0) / 24_000)) }
                let duration = try MorningReportAudio.write(samples: samples, sampleRate: 24_000, to: outputURL)
                return ArticleNarrationAudio(
                    audioURL: outputURL, duration: duration,
                    voiceRevision: ArticleNarrationCoordinator.shortTextVoiceRevision(for: voiceID))
            },
            coordinates: { (35.0, -80.0) }, forecast: { _, _ in periods },
            headlines: { _, _ in MorningReportHeadlines(hasNewsFeeds: true, titles: ["A headline"]) },
            calendar: Calendar(identifier: .gregorian))
        let secondOutcome = await secondBuilder.build(now: Date(timeIntervalSince1970: 1_800_000_000))
        guard case let .published(secondItemID, _, _, _, _) = secondOutcome else {
            return XCTFail("expected the changed voice to publish a report, got \(secondOutcome)")
        }
        XCTAssertNotEqual(itemID, secondItemID)
        XCTAssertEqual(selectedVoices.all, [.caseyKasem, .rodSerling])
    }

    func testAnOverlongSynthesisIsRedoneWithOneFewerHeadline() async throws {
        let (store, _) = try makeStore()
        let calls = Calls()
        let outcome = await builder(store, calls, news: headlines(10)) { $0 == 1 ? 320 : 2 }
            .build(now: Date(timeIntervalSince1970: 1_800_000_000))
        guard case let .published(_, _, duration, count, _) = outcome else { return XCTFail("expected a report, got \(outcome)") }
        XCTAssertEqual(calls.all.count, 2)
        XCTAssertEqual(headlineCount(calls.all[0]), 5)
        XCTAssertEqual(headlineCount(calls.all[1]), 4)
        XCTAssertEqual(count, 4)
        XCTAssertLessThanOrEqual(duration, 300)
    }

    func testWhenEveryAttemptIsTooLongNothingIsPublishedAndThePreviousReportStays() async throws {
        let (store, _) = try makeStore()
        let first = await builder(store, Calls(), news: headlines(3)).build(now: Date(timeIntervalSince1970: 1_800_000_000))
        guard case let .published(previousID, _, _, _, _) = first else { return XCTFail("expected a first report, got \(first)") }

        let calls = Calls()
        let second = await builder(store, calls, news: headlines(5)) { _ in 320 }.build(now: Date(timeIntervalSince1970: 1_800_090_000))
        guard case let .skipped(reason) = second else { return XCTFail("expected no report, got \(second)") }
        XCTAssertTrue(reason.contains("previous report stays"), reason)
        // Three headline attempts, then one with the forecast shortened to today's first period.
        XCTAssertEqual(calls.all.count, 4)
        XCTAssertEqual(headlineCount(calls.all[2]), 3)
        XCTAssertFalse(calls.all[3].contains("Tonight"))
        let books = try await store.audiobooks()
        XCTAssertEqual(books.map(\.itemID), [previousID])
        XCTAssertEqual(books.first?.isRemoved, false)
        let queue = try await store.podcastQueueState()
        XCTAssertEqual(queue.episodeIDs, [previousID])
    }

    func testASavedReportIsListedAfterAModelReloadAndStartsPlayingFromTheQueue() async throws {
        let (store, directory) = try makeStore()
        let outcome = await builder(store, Calls(), news: headlines(3)).build(now: Date(timeIntervalSince1970: 1_800_000_000))
        guard case let .published(itemID, title, _, _, _) = outcome else { return XCTFail("expected a report, got \(outcome)") }
        XCTAssertTrue(title.hasPrefix("Morning report, "), title)

        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { _ in store }, preferences: WiltedMacTestPreferences.ephemeral())
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        await model.reloadLibraryRowsForTesting()
        await model.refreshPodcastQueueState()

        let row = try XCTUnwrap(model.episodes.first { $0.id == itemID.rawValue }, "the report is listed after a reload")
        XCTAssertTrue(row.isReport)
        XCTAssertEqual(row.title, title)
        XCTAssertTrue(model.canPlayEpisode(row))
        model.playLarderEpisode(row)
        await WiltedMacHeadless.eventually("the report is playing") {
            model.currentPodcastEpisodeID == itemID.rawValue && model.isPlaying
        }
        XCTAssertEqual(model.podcastQueueIDs, [itemID.rawValue])
    }

    func testAHugeWhitespaceFreeForecastIsCappedBeforeSynthesis() async throws {
        let (store, _) = try makeStore()
        let calls = Calls()
        let huge = String(repeating: "x", count: 1_000_000)
        let builder = MorningReportBuilder(
            store: store, voiceID: .caseyKasem, renderVoice: voiceRenderer(calls),
            coordinates: { (35.0, -80.0) }, forecast: { _, _ in [MorningReportForecastPeriod(name: "Today", text: huge)] },
            headlines: { _, _ in MorningReportHeadlines(hasNewsFeeds: true, titles: [huge]) }, calendar: Calendar(identifier: .gregorian))
        _ = await builder.build(now: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertFalse(calls.all.isEmpty)
        for text in calls.all { XCTAssertLessThanOrEqual(text.count, MorningReportBuilder.maximumScriptCharacters) }
        XCTAssertGreaterThanOrEqual(MorningReportBuilder.estimatedSeconds(huge), 300, "a no-space token estimates long")
    }

    func testUTF8OverflowSkipsInsteadOfClippingTheReport() async throws {
        let (store, _) = try makeStore()
        let calls = Calls()
        let periods = (1...5).map { _ in
            MorningReportForecastPeriod(name: "Today", text: String(repeating: "🌤", count: 1_000))
        }
        let builder = MorningReportBuilder(
            store: store, voiceID: .caseyKasem, renderVoice: voiceRenderer(calls),
            coordinates: { (35.0, -80.0) }, forecast: { _, _ in periods },
            headlines: { _, _ in MorningReportHeadlines(hasNewsFeeds: true, titles: []) },
            calendar: Calendar(identifier: .gregorian))

        let outcome = await builder.build(now: Date(timeIntervalSince1970: 1_800_000_000))

        guard case let .skipped(reason) = outcome else { return XCTFail("expected a skip, got \(outcome)") }
        XCTAssertEqual(reason, "No report built: the report text exceeds the local voice limit.")
        XCTAssertTrue(calls.all.isEmpty, "oversized UTF-8 text is rejected before voice rendering")
    }

    func testBuildingTwiceForTheSameReportLeavesNoOrphanMedia() async throws {
        let (store, _) = try makeStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = await builder(store, Calls(), news: headlines(2)).build(now: now)
        guard case .published = first else { return XCTFail("expected a report, got \(first)") }
        let second = await builder(store, Calls(), news: headlines(2)).build(now: now)
        guard case .skipped = second else { return XCTFail("expected the repeat to be skipped, got \(second)") }
        let files = try FileManager.default.contentsOfDirectory(atPath: store.mediaDirectory.path).filter { $0.hasSuffix(".m4a") }
        let snapshot = try await store.podcastLibrarySnapshot()
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(snapshot.readyRevisions.count, 1, "records equal audio")
    }

    func testTwoBuildsThatBothPassThePrecheckLeaveOneFileAndOnePublishedOutcome() async throws {
        let (store, _) = try makeStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let barrier = Barrier(parties: 2)
        let periods = self.periods
        func racing() -> MorningReportBuilder {
            MorningReportBuilder(
                store: store, voiceID: .caseyKasem, renderVoice: voiceRenderer(Calls()),
                coordinates: { (35.0, -80.0) }, forecast: { _, _ in periods }, headlines: { _, _ in MorningReportHeadlines(hasNewsFeeds: true, titles: ["Headline1 a b c"]) },
                calendar: Calendar(identifier: .gregorian), afterPrecheck: { await barrier.arrive() })
        }
        let a = racing(), b = racing()
        async let first = a.build(now: now)
        async let second = b.build(now: now)
        let outcomes = await [first, second]
        let published = outcomes.filter { if case .published = $0 { return true } else { return false } }
        XCTAssertEqual(published.count, 1, "exactly one build reports published: \(outcomes)")
        let files = try FileManager.default.contentsOfDirectory(atPath: store.mediaDirectory.path).filter { $0.hasSuffix(".m4a") }
        XCTAssertEqual(files.count, 1)
        let snapshot = try await store.podcastLibrarySnapshot()
        XCTAssertEqual(snapshot.readyRevisions.count, 1)
    }

    /// Releases every caller once `parties` have arrived.
    private actor Barrier {
        private let parties: Int
        private var waiting: [CheckedContinuation<Void, Never>] = []
        init(parties: Int) { self.parties = parties }
        func arrive() async {
            if waiting.count + 1 >= parties {
                waiting.forEach { $0.resume() }
                waiting = []
            } else {
                await withCheckedContinuation { waiting.append($0) }
            }
        }
    }

    func testNoLocationYieldsAHeadlinesOnlyReportThatNamesTheMissingWeather() async throws {
        let (store, _) = try makeStore()
        let calls = Calls()
        let outcome = await builder(store, calls, news: headlines(2), located: false).build(now: Date(timeIntervalSince1970: 1_800_000_000))
        guard case .published = outcome else { return XCTFail("expected a report, got \(outcome)") }
        let text = try XCTUnwrap(calls.all.first)
        XCTAssertTrue(text.contains("The weather is not included, because no location is set."), text)
        XCTAssertFalse(text.contains("Sunny"))
        XCTAssertEqual(headlineCount(text), 2)
    }

    func testNoHeadlineFeedsYieldsAWeatherOnlyReportThatSaysSo() async throws {
        let (store, _) = try makeStore()
        let calls = Calls()
        let outcome = await builder(store, calls, news: MorningReportHeadlines(hasNewsFeeds: false, titles: []))
            .build(now: Date(timeIntervalSince1970: 1_800_000_000))
        guard case .published = outcome else { return XCTFail("expected a report, got \(outcome)") }
        XCTAssertTrue(try XCTUnwrap(calls.all.first).contains("No headline feeds are set up"))
    }

    func testFreshHeadlinesComeFromTheFeedEvenWhenPostsAreNotSavedAsArticles() async throws {
        let (store, _) = try makeStore()
        let now = Date(timeIntervalSince1970: 1_767_704_400)
        let feedURL = URL(string: "https://headlines.example.test/rss.xml")!
        let feed = try ArticleFeed(canonicalURL: feedURL, title: "Daily headlines", createdAt: Timestamp(now))
        try await store.save(articleFeed: feed)
        try await store.save(isNews: true, feedID: feed.itemID)
        try await store.save(subscription: PodcastSubscription(feedID: feed.itemID, subscribedAt: Timestamp(now)))

        let unsubscribed = try ArticleFeed(
            canonicalURL: URL(string: "https://headlines.example.test/unsubscribed.xml")!,
            title: "Unsubscribed headlines", createdAt: Timestamp(now))
        try await store.save(articleFeed: unsubscribed)
        try await store.save(isNews: true, feedID: unsubscribed.itemID)
        let xml = "<rss version=\"2.0\"><channel><title>Daily headlines</title>"
            + "<item><guid>fresh</guid><title>Fresh story</title><link>https://headlines.example.test/fresh</link>"
            + "<pubDate>Tue, 06 Jan 2026 12:30:00 GMT</pubDate></item>"
            + "<item><guid>old</guid><title>Old story</title><link>https://headlines.example.test/old</link>"
            + "<pubDate>Tue, 06 Jan 2026 10:00:00 GMT</pubDate></item>"
            + "<item><guid>future</guid><title>Future story</title><link>https://headlines.example.test/future</link>"
            + "<pubDate>Tue, 06 Jan 2026 13:30:00 GMT</pubDate></item>"
            + "<item><guid>sports</guid><title>Premier League final</title><link>https://headlines.example.test/sports</link>"
            + "<pubDate>Tue, 06 Jan 2026 12:45:00 GMT</pubDate></item>"
            + "</channel></rss>"
        let client = PodcastFeedClient(loader: FixedBodyLoader(body: Data(xml.utf8)))
        let calls = Calls()
        let periods = self.periods
        let builder = MorningReportBuilder(
            store: store, voiceID: .caseyKasem, renderVoice: voiceRenderer(calls),
            coordinates: { (35.0, -80.0) }, forecast: { _, _ in periods }, feedClient: client,
            topics: HeadlineTopicFilter(skipSports: true),
            calendar: Calendar(identifier: .gregorian))

        let outcome = await builder.build(now: now)
        guard case let .published(_, _, _, count, _) = outcome else { return XCTFail("expected a report, got \(outcome)") }
        let text = try XCTUnwrap(calls.all.first)
        XCTAssertEqual(count, 1)
        XCTAssertTrue(text.contains("Fresh story"), text)
        XCTAssertFalse(text.contains("Old story"), text)
        XCTAssertFalse(text.contains("Future story"), "future posts are outside the report window")
        XCTAssertFalse(text.contains("Premier League"), "saved topic exclusions apply to the report")
        let savedArticles = try await store.articles()
        XCTAssertTrue(savedArticles.isEmpty, "headline-only posts are not saved as articles")
    }

    func testSharedHeadlineReaderKeepsTheBulletinFiftyPostPerFeedCap() async throws {
        let (store, _) = try makeStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let feedURL = URL(string: "https://headlines.example.test/cap.xml")!
        let feed = try ArticleFeed(canonicalURL: feedURL, title: "Daily headlines", createdAt: Timestamp(now))
        try await store.save(articleFeed: feed)
        try await store.save(isNews: true, feedID: feed.itemID)
        try await store.save(subscription: PodcastSubscription(feedID: feed.itemID, subscribedAt: Timestamp(now)))

        let items = (1...51).map { index in
            "<item><guid>post-\(index)</guid><title>Story \(index)</title>"
                + "<link>https://headlines.example.test/story-\(index)</link></item>"
        }.joined()
        let xml = "<rss version=\"2.0\"><channel><title>Daily headlines</title>\(items)</channel></rss>"
        let client = PodcastFeedClient(loader: FixedBodyLoader(body: Data(xml.utf8)))

        let supply = try await NewsHeadlineCandidateReader.read(in: store, using: client)
        XCTAssertEqual(supply.candidates.count, 50)
    }

    func testHeadlineFeedEligibilityUsesSubscriptionIdentityWhenEpisodeVisibilityIsOff() async throws {
        let (store, _) = try makeStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let feed = try ArticleFeed(
            canonicalURL: URL(string: "https://headlines.example.test/hidden-episodes.xml")!,
            title: "Daily headlines", createdAt: Timestamp(now))
        try await store.save(articleFeed: feed)
        try await store.save(isNews: true, feedID: feed.itemID)
        try await store.save(subscription: PodcastSubscription(feedID: feed.itemID, subscribedAt: Timestamp(now), enabled: false))

        let feeds = try await NewsHeadlineCandidateReader.headlineFeeds(in: store)
        XCTAssertEqual(feeds.map(\.itemID), [feed.itemID])
    }

    func testNothingToSayPublishesNothingAndGivesAReason() async throws {
        let (store, _) = try makeStore()
        let outcome = await builder(store, Calls(), news: MorningReportHeadlines(hasNewsFeeds: false, titles: []), located: false)
            .build(now: Date(timeIntervalSince1970: 1_800_000_000))
        guard case let .skipped(reason) = outcome else { return XCTFail("expected no report, got \(outcome)") }
        XCTAssertTrue(reason.contains("no location is set"), reason)
    }

    func testThePublishedReportFileLoadsWithAVURLAsset() async throws {
        let (store, _) = try makeStore()
        let outcome = await builder(store, Calls(), news: headlines(2)).build(now: Date(timeIntervalSince1970: 1_800_000_000))
        guard case let .published(itemID, _, _, _, _) = outcome else { return XCTFail("expected a report, got \(outcome)") }
        let snapshot = try await store.podcastLibrarySnapshot()
        let url = try XCTUnwrap(snapshot.readyRevisions[itemID]?.mediaURL)
        XCTAssertEqual(url.pathExtension, "m4a")
        let seconds = try await AVURLAsset(url: url).load(.duration).seconds
        XCTAssertEqual(seconds, 2, accuracy: 0.2)
    }

    func testAnOfflineHeadlineFailureGivesTheOfflineSentence() async throws {
        let (store, _) = try makeStore()
        let periods = self.periods
        let builder = MorningReportBuilder(
            store: store, voiceID: .caseyKasem, renderVoice: voiceRenderer(Calls()),
            coordinates: { (35.0, -80.0) }, forecast: { _, _ in periods },
            headlines: { _, _ in
                throw URLError(
                    .notConnectedToInternet,
                    userInfo: [NSURLErrorFailingURLStringErrorKey: "https://news.example.test/x?token=SECRET-TOKEN"])
            },
            calendar: Calendar(identifier: .gregorian))
        let outcome = await builder.build(now: Date(timeIntervalSince1970: 1_800_000_000))
        guard case let .skipped(reason) = outcome else { return XCTFail("expected a skip, got \(outcome)") }
        XCTAssertEqual(reason, "No report published: this Mac is offline.")
        assertPlain(reason)
    }

    func testASpeechFailureGivesTheSpeechEngineSentence() async throws {
        let (store, _) = try makeStore()
        let periods = self.periods
        let news = headlines(2)
        let builder = MorningReportBuilder(
            store: store, voiceID: .caseyKasem,
            renderVoice: { _, _, _ in throw ArticleNarrationError.runtimeUnavailable },
            coordinates: { (35.0, -80.0) }, forecast: { _, _ in periods },
            headlines: { _, _ in news }, calendar: Calendar(identifier: .gregorian))
        let outcome = await builder.build(now: Date(timeIntervalSince1970: 1_800_000_000))
        guard case let .skipped(reason) = outcome else { return XCTFail("expected a skip, got \(outcome)") }
        XCTAssertEqual(reason, "No report published: the speech engine is not available.")
        assertPlain(reason)
    }

    func testAnUnknownHeadlineFailureGivesTheFallbackSentence() async throws {
        let (store, _) = try makeStore()
        let periods = self.periods
        let builder = MorningReportBuilder(
            store: store, voiceID: .caseyKasem, renderVoice: voiceRenderer(Calls()),
            coordinates: { (35.0, -80.0) }, forecast: { _, _ in periods },
            headlines: { _, _ in throw PlainFailure() }, calendar: Calendar(identifier: .gregorian))
        let outcome = await builder.build(now: Date(timeIntervalSince1970: 1_800_000_000))
        guard case let .skipped(reason) = outcome else { return XCTFail("expected a skip, got \(outcome)") }
        XCTAssertEqual(reason, "No report published: something went wrong while building it. Try Build now.")
        assertPlain(reason)
    }

    func testTheScheduleRunsAtTheTimeAndMakesUpAMissedRunWithinTwoHours() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let time = try XCTUnwrap(WiltedAutomationLocalTime(hour: 7, minute: 0))
        func at(_ hour: Int, _ minute: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: hour, minute: minute))!
        }
        XCTAssertFalse(MorningReportSchedule.isDue(now: at(6, 59), time: time, lastRunDay: nil, calendar: calendar))
        XCTAssertTrue(MorningReportSchedule.isDue(now: at(7, 0), time: time, lastRunDay: nil, calendar: calendar))
        XCTAssertTrue(MorningReportSchedule.isDue(now: at(8, 59), time: time, lastRunDay: nil, calendar: calendar))
        XCTAssertFalse(MorningReportSchedule.isDue(now: at(9, 1), time: time, lastRunDay: nil, calendar: calendar))
        XCTAssertFalse(MorningReportSchedule.isDue(
            now: at(7, 30), time: time, lastRunDay: MorningReportSchedule.dayKey(at(7, 0), calendar: calendar), calendar: calendar))
    }
}
