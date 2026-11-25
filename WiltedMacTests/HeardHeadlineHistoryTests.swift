import Foundation
import XCTest
@testable import WiltedMac
import WiltedLibrary
import WiltedProducer

@MainActor
final class HeardHeadlineHistoryTests: XCTestCase {
    private let title = "Japan earthquake kills 3 after tsunami warning for Pacific coast"
    private let reworded = "Tsunami warning issued after earthquake kills 3 on Japan Pacific coast"
    private let update = "Update: Japan earthquake kills 40 after tsunami warning, evacuation declared on Pacific coast"

    func testFailedStartRetriesAndHeardChannelHeadlineSurvivesReenableAndRelaunch() async throws {
        let library = try await AccountingLibrary.make(in: wiltedTemporaryDirectory("heard-headline"))
        let clock = BulletinProducerHarness()
        let speakers = HeadlineSpeakerFactory(startResults: [false, true, true])
        let initial = installHub(on: library.model, clock: clock, speakers: speakers)
        _ = library.installScriptedPlayback(on: library.model)
        library.model.playEpisode(library.episodes[0])
        await library.model.waitForPlaybackOperationForTesting()
        configure(library.model, wait: 10)

        let original = try bulletin("headline:npr", "NPR. \(title)", at: clock.now)
        try publishCatalog([original], on: library.model, at: clock.now)
        let liveChannel = try channel([original], at: clock.now)
        initial.channelUpdated(try channel([], at: clock.now))
        initial.channelUpdated(liveChannel)
        await WiltedMacHeadless.eventually("the first voice attempt starts after rendering") {
            speakers.all.first?.attempts == 1
        }
        XCTAssertEqual(speakers.all.map(\.attempts), [1])
        XCTAssertEqual(speakers.all.flatMap(\.texts), [])

        configure(library.model, wait: 20)
        await WiltedMacHeadless.eventually("the selected voice retries the failed start") {
            speakers.all.count >= 2 && speakers.all[1].texts == [original.text]
        }
        XCTAssertEqual(speakers.all.flatMap(\.texts), [original.text], "failed starts can be retried")
        clock.advance(minutes: 40)
        configure(library.model, wait: 30)
        XCTAssertEqual(speakers.all.map(\.attempts), [1, 1, 0], "re-enabling syncs the same live channel")
        await library.model.close()

        let relaunched = library.relaunch()
        let freshSpeakers = HeadlineSpeakerFactory(startResults: [true])
        let hub = installHub(on: relaunched, clock: clock, speakers: freshSpeakers)
        relaunched.startStoreBootstrap()
        await relaunched.waitForStoreBootstrap()
        let (backend, _) = library.installScriptedPlayback(on: relaunched)
        relaunched.playEpisode(library.episodes[0])
        await relaunched.waitForPlaybackOperationForTesting()
        hub.reconcile()
        XCTAssertTrue(hub.interruptionsAreAttached)
        XCTAssertTrue(backend.isPlaying)

        hub.channelUpdated(liveChannel)
        let copy = try bulletin("headline:bbc", "BBC. \(reworded)", at: clock.now)
        try publishCatalog([copy], on: relaunched, at: clock.now)
        hub.channelUpdated(try channel([copy], at: clock.now))
        XCTAssertTrue(freshSpeakers.all.flatMap(\.texts).isEmpty)
        let major = try bulletin("headline:ap", "AP. \(update)", at: clock.now)
        try publishCatalog([major], on: relaunched, at: clock.now)
        hub.channelUpdated(try channel([major], at: clock.now))
        await WiltedMacHeadless.eventually("an eligible major update is rendered and spoken") {
            freshSpeakers.all.flatMap(\.texts) == [major.text]
        }
        XCTAssertEqual(freshSpeakers.all.flatMap(\.texts), [major.text])
        await relaunched.close()
    }

    func testNewProducerRejectsCrossFeedCopyAndPublishesMajorUpdate() async throws {
        let feed = BulletinProducerHarness()
        let preferences = WiltedMacTestPreferences.ephemeral()
        HeardHeadlineHistory(defaults: preferences, now: feed.now)
            .record(id: "headline:npr", title: title, at: feed.now)
        feed.advance(minutes: 90) // The original has already disappeared from the hourly channel.
        let model = WiltedMacModel(arguments: [], preferences: preferences)
        let hub = installHub(on: model, clock: feed, speakers: HeadlineSpeakerFactory(startResults: [true]))
        configure(model, wait: 10)
        defer { withExtendedLifetime(model) {} }
        let producer = scriptedProducer(hub, feed)
        feed.items = [post("bbc", title: reworded, feed: feed)]
        await producer.poll()
        XCTAssertEqual(feed.published?.headlines.map(\.id), [])
        feed.items = [post("ap", title: update, feed: feed)]
        await producer.poll()
        XCTAssertEqual(feed.published?.headlines.map(\.id), ["headline:ap"])
    }

    func testHistoryForgetsBothIDAndTitleAfterTwentyFourHours() async throws {
        let feed = BulletinProducerHarness()
        let preferences = WiltedMacTestPreferences.ephemeral()
        HeardHeadlineHistory(defaults: preferences, now: feed.now)
            .record(id: "headline:npr", title: title, at: feed.now)
        for hours in [23, 25] {
            feed.advance(minutes: hours == 23 ? 23 * 60 : 2 * 60)
            let model = WiltedMacModel(arguments: [], preferences: preferences)
            let hub = installHub(on: model, clock: feed, speakers: HeadlineSpeakerFactory(startResults: [true]))
            configure(model, wait: 10)
            defer { withExtendedLifetime(model) {} }
            let producer = scriptedProducer(hub, feed)
            feed.items = [post("npr", title: title, feed: feed)]
            await producer.poll()
            XCTAssertEqual(feed.published?.headlines.map(\.id), hours == 23 ? [] : ["headline:npr"])
        }
    }

    private func scriptedProducer(_ hub: WiltedMacBulletinHub, _ feed: BulletinProducerHarness) -> BulletinProducer {
        hub.makeProducer(newsItems: { feed.items }, fetchPublished: { feed.published }, publish: { feed.published = $0 })
    }

    private func installHub(on model: WiltedMacModel, clock: BulletinProducerHarness,
                            speakers: HeadlineSpeakerFactory) -> WiltedMacBulletinHub {
        let location = WiltedLocationProvider(manager: HubFakeLocationManager(), wifi: HubFakeWiFi())
        let hub = WiltedMacBulletinHub(model: model, location: location, makeSpeaker: { speakers.make() },
                                      makeRouteSource: { HeadlineTestRoute() }, makeAlertSource: { _ in HubCountingSource() },
                                      now: { clock.now }, producerFactory: { clock.producer() },
                                      makeHeadlineNarration: { self.makeNarration(now: { clock.now }) })
        model.installBulletinHubForTesting(hub)
        model.selectReadingVoice(ApprovedReadingVoiceID.caseyKasem.rawValue)
        return hub
    }

    private func makeNarration(now: @escaping @Sendable () -> Date) -> WiltedMacHeadlineNarration {
        WiltedMacHeadlineNarration(
            render: { _, voiceID, outputURL in
                try Data(repeating: 0x39, count: 128).write(to: outputURL)
                return ArticleNarrationAudio(
                    audioURL: outputURL, duration: 1,
                    voiceRevision: ArticleNarrationCoordinator.voiceRevision(for: voiceID))
            },
            availability: { _ in .available }, now: now)
    }

    private func configure(_ model: WiltedMacModel, wait: Int) {
        model.updateAutomationSettings { current in
            current.updatingReports {
                $0.interruptionsEnabled = true
                $0.alertsEnabled = false
                $0.headlinesEnabled = true
                $0.waitLimitSeconds = wait
            }
        }
        model.bulletinHub.reconcile()
    }

    private func post(_ id: String, title: String, feed: BulletinProducerHarness) -> NewsHeadlineCandidate {
        NewsHeadlineCandidate(id: id, feedTitle: id, title: title, publishedAt: feed.now)
    }

    private func bulletin(_ id: String, _ text: String, at time: Date) throws -> Bulletin {
        // Immediate scheduling makes a mistaken replay observable in this call.
        let publisherID = String(id.dropFirst("headline:".count))
        let publisherName = String(text.prefix { $0 != "." })
        let storyID = publisherID
        let link = URL(string: "https://\(publisherID).example.test/\(storyID)")
        return try Bulletin(id: id, kind: .headline, text: text, severity: .extreme,
                            issuedAt: time, expiresAt: time.addingTimeInterval(3600), storyID: storyID,
                            publisherID: publisherID, publisherName: publisherName,
                            headline: BulletinProducer.headlineTitle(of: text), link: link, publishedAt: time)
    }

    private func publishCatalog(_ bulletins: [Bulletin], on model: WiltedMacModel, at time: Date) throws {
        let stories = try bulletins.map { bulletin -> LibraryHeadlineStory in
            try LibraryHeadlineStory(
                id: XCTUnwrap(bulletin.headlineStoryID),
                title: XCTUnwrap(bulletin.headline),
                publisherID: try XCTUnwrap(bulletin.publisherID),
                publisherName: try XCTUnwrap(bulletin.publisherName),
                link: bulletin.link,
                publishedAt: bulletin.publishedAt ?? time,
                firstSeenAt: time,
                lastSeenAt: time)
        }
        _ = try model.headlineCatalogStore.mergeRecent(stories, at: time)
        model.headlineCatalogState.refresh(at: time)
    }

    private func channel(_ bulletins: [Bulletin], at time: Date) throws -> LibraryBulletins {
        try LibraryBulletins(alertsEnabled: false, headlinesEnabled: true, headlines: bulletins, updatedAt: time)
    }
}

@MainActor
private final class HeadlineTestSpeaker: BulletinSpeaking {
    let startsSpeech: Bool
    private(set) var attempts = 0
    private(set) var texts: [String] = []

    init(startsSpeech: Bool) { self.startsSpeech = startsSpeech }

    func speak(_ text: String, playbackVolume: Float, finished: @escaping @MainActor () -> Void) -> Bool {
        attempts += 1
        guard startsSpeech else { return false }
        texts.append(text)
        return true
    }

    /// Selected-voice test double: headlines are accepted through the typed bulletin path.
    func speak(_ bulletin: Bulletin, playbackVolume: Float,
               finished: @escaping @MainActor () -> Void) -> Bool {
        guard bulletin.kind == .headline else { return false }
        return speak(bulletin.text, playbackVolume: playbackVolume, finished: finished)
    }

    func stop() {}
}

@MainActor
private final class HeadlineSpeakerFactory {
    private let startResults: [Bool]
    private(set) var all: [HeadlineTestSpeaker] = []

    init(startResults: [Bool]) { self.startResults = startResults }

    func make() -> HeadlineTestSpeaker {
        let result = startResults[min(all.count, startResults.count - 1)]
        let speaker = HeadlineTestSpeaker(startsSpeech: result)
        all.append(speaker)
        return speaker
    }
}

@MainActor
private final class HeadlineTestRoute: MacAudioRouteSource {
    var changed: (@MainActor () -> Void)?
    func start(changed: @escaping @MainActor () -> Void) -> Bool { self.changed = changed; return true }
    func currentRoute() -> MacAudioRoute? { MacAudioRoute(device: 1) }
    func stop() { changed = nil }
}
