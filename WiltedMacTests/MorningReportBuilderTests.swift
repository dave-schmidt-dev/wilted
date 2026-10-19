import AVFoundation
import Foundation
import XCTest
import WiltedDomain
@testable import WiltedProducer
@testable import WiltedMac

private struct PlainFailure: Error {}

/// Builder behaviour with an injected stub synthesizer (never real speech), a stub forecast and
/// stub headlines. "Long" results carry a low sample rate so 320 s costs few samples and is never encoded.
@MainActor
final class MorningReportBuilderTests: XCTestCase {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var texts: [String] = []
        func record(_ text: String) -> Int { lock.lock(); defer { lock.unlock() }; texts.append(text); return texts.count }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return texts }
    }

    /// Returns `seconds(callNumber)` of audio per call; short results use a real 24 kHz tone.
    private func stub(_ calls: Calls, seconds: @escaping @Sendable (Int) -> Double) -> BookConversion.Synthesizer {
        { text, _ in
            let seconds = seconds(calls.record(text))
            if seconds > 30 {
                return SpeechSynthesisResult(requestID: "stub", samples: [Float](repeating: 0.1, count: Int(seconds * 1000)), sampleRate: 1000)
            }
            let samples = (0..<Int(seconds * 24_000)).map { Float(0.3 * sin(2 * Double.pi * 330 * Double($0) / 24_000)) }
            return SpeechSynthesisResult(requestID: "stub", samples: samples, sampleRate: 24_000)
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
            store: store, synthesize: stub(calls, seconds: seconds),
            coordinates: { located ? (35.0, -80.0) : nil }, forecast: { _, _ in periods },
            headlines: { _ in news }, calendar: Calendar(identifier: .gregorian))
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
            store: store, synthesize: stub(calls) { _ in 2 },
            coordinates: { (35.0, -80.0) }, forecast: { _, _ in [MorningReportForecastPeriod(name: "Today", text: huge)] },
            headlines: { _ in MorningReportHeadlines(hasNewsFeeds: true, titles: [huge]) }, calendar: Calendar(identifier: .gregorian))
        _ = await builder.build(now: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertFalse(calls.all.isEmpty)
        for text in calls.all { XCTAssertLessThanOrEqual(text.count, MorningReportBuilder.maximumScriptCharacters) }
        XCTAssertGreaterThanOrEqual(MorningReportBuilder.estimatedSeconds(huge), 300, "a no-space token estimates long")
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
                store: store, synthesize: stub(Calls(), seconds: { _ in 2 }),
                coordinates: { (35.0, -80.0) }, forecast: { _, _ in periods }, headlines: { _ in MorningReportHeadlines(hasNewsFeeds: true, titles: ["Headline1 a b c"]) },
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

    func testNoNewsFeedsYieldsAWeatherOnlyReportThatSaysSo() async throws {
        let (store, _) = try makeStore()
        let calls = Calls()
        let outcome = await builder(store, calls, news: MorningReportHeadlines(hasNewsFeeds: false, titles: []))
            .build(now: Date(timeIntervalSince1970: 1_800_000_000))
        guard case .published = outcome else { return XCTFail("expected a report, got \(outcome)") }
        XCTAssertTrue(try XCTUnwrap(calls.all.first).contains("No news feeds are set up"))
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
            store: store, synthesize: stub(Calls()) { _ in 2 },
            coordinates: { (35.0, -80.0) }, forecast: { _, _ in periods },
            headlines: { _ in
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
            store: store, synthesize: { _, _ in throw SpeechIPCError.timeout("speech") },
            coordinates: { (35.0, -80.0) }, forecast: { _, _ in periods },
            headlines: { _ in news }, calendar: Calendar(identifier: .gregorian))
        let outcome = await builder.build(now: Date(timeIntervalSince1970: 1_800_000_000))
        guard case let .skipped(reason) = outcome else { return XCTFail("expected a skip, got \(outcome)") }
        XCTAssertEqual(reason, "No report published: the speech engine is not available.")
        assertPlain(reason)
    }

    func testAnUnknownHeadlineFailureGivesTheFallbackSentence() async throws {
        let (store, _) = try makeStore()
        let periods = self.periods
        let builder = MorningReportBuilder(
            store: store, synthesize: stub(Calls()) { _ in 2 },
            coordinates: { (35.0, -80.0) }, forecast: { _, _ in periods },
            headlines: { _ in throw PlainFailure() }, calendar: Calendar(identifier: .gregorian))
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
