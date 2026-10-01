@preconcurrency import Intents
import UIKit
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltediOS

/// The in-app `INPlayMediaIntent` handler behind spoken play requests: what Siri
/// understood maps onto the same planner the App Intents use, and only downloaded episodes play.
@MainActor
final class PlayMediaIntentTests: XCTestCase {
    private var savedProvider: (@MainActor () async -> (any VoiceCommandTarget)?)!

    override func setUp() async throws { savedProvider = VoiceRuntime.provider }
    override func tearDown() async throws { VoiceRuntime.provider = savedProvider }

    private func episode(_ raw: String, _ title: String, _ show: String, day: Double = 0) throws -> VoiceEpisode {
        VoiceEpisode(
            id: try ItemID(rawValue: raw), title: title, showTitle: show, publishedAt: Date(timeIntervalSince1970: day * 86_400))
    }

    private func install(_ episodes: [VoiceEpisode]) -> RecordingTarget {
        let target = RecordingTarget(snapshot: VoiceSnapshot(
            downloaded: episodes, knownShowTitles: Array(Set(episodes.map(\.showTitle))).sorted(), nowPlaying: nil))
        VoiceRuntime.provider = { target }
        return target
    }

    private func search(
        type: INMediaItemType = .unknown, sort: INMediaSortOrder = .unknown, name: String? = nil, artist: String? = nil
    ) -> INMediaSearch {
        INMediaSearch(
            mediaType: type, sortOrder: sort, mediaName: name, artistName: artist, albumName: nil, genreNames: nil,
            moodNames: nil, releaseDate: nil, reference: .unknown, mediaIdentifier: nil)
    }

    private func intent(search: INMediaSearch?, items: [INMediaItem]? = nil) -> INPlayMediaIntent {
        INPlayMediaIntent(
            mediaItems: items, mediaContainer: nil, playShuffled: nil, playbackRepeatMode: .unknown, resumePlayback: nil,
            playbackQueueLocation: .unknown, playbackSpeed: nil, mediaSearch: search)
    }

    // MARK: mapping

    func testRequestMapping() {
        XCTAssertEqual(PlayMediaRequest.commands(for: nil), [.playNext(show: nil)])
        XCTAssertEqual(PlayMediaRequest.commands(for: search(sort: .newest)), [.playLatest(show: nil)])
        XCTAssertEqual(PlayMediaRequest.commands(for: search(type: .podcastShow, name: " Planet Money ")), [.playNext(show: "Planet Money")])
        XCTAssertEqual(PlayMediaRequest.commands(for: search(type: .podcastShow, sort: .newest, name: "Planet Money")), [.playLatest(show: "Planet Money")])
        XCTAssertEqual(
            PlayMediaRequest.commands(for: search(type: .podcastEpisode, name: "Chips", artist: "Planet Money")),
            [.playEpisode(title: "Chips", show: "Planet Money")])
        XCTAssertEqual(
            PlayMediaRequest.commands(for: search(name: "Chips")),
            [.playEpisode(title: "Chips", show: nil), .playNext(show: "Chips")], "a bare name is an episode title first, then a show")
    }

    // MARK: resolve and handle

    func testBareNameResolvesToAnEpisodeThenToAShow() async throws {
        let chips = try episode("b", "Chips", "Planet Money", day: 9)
        _ = install([try episode("a", "Gold Rush", "Planet Money", day: 1), chips, try episode("c", "Other", "The Daily")])
        let byTitle = await PlayMediaCore.episode(for: PlayMediaRequest.commands(for: search(name: "Chips")))
        XCTAssertEqual(byTitle?.id, chips.id)
        let byShow = await PlayMediaCore.episode(for: PlayMediaRequest.commands(for: search(name: "The Daily")))
        XCTAssertEqual(byShow?.title, "Other")
        let none = await PlayMediaCore.episode(for: PlayMediaRequest.commands(for: search(name: "Nothing Like This")))
        XCTAssertNil(none, "a request for something not on the phone resolves to nothing")
    }

    func testHandlePlaysTheResolvedEpisodeThroughTheTarget() async throws {
        let chips = try episode("b", "Chips", "Planet Money")
        let target = install([try episode("a", "Gold Rush", "Planet Money"), chips])
        let handler = PlayMediaIntentHandler()
        let item = INMediaItem(identifier: chips.id.rawValue, title: chips.title, type: .podcastEpisode, artwork: nil, artist: chips.showTitle)
        let response = await handler.handle(intent: intent(search: nil, items: [item]))
        XCTAssertEqual(response.code, .success)
        XCTAssertEqual(target.performed, [.play(chips.id)])
    }

    func testHandleFallsBackToTheSearchWhenNothingWasResolved() async throws {
        let chips = try episode("b", "Chips", "Planet Money")
        let target = install([chips])
        let response = await PlayMediaIntentHandler().handle(intent: intent(search: search(type: .podcastEpisode, name: "Chips")))
        XCTAssertEqual(response.code, .success)
        XCTAssertEqual(target.performed, [.play(chips.id)])
    }

    func testHandleFailsAndPlaysNothingWhenNoEpisodeMatchesOrTheTargetFails() async throws {
        let target = install([try episode("a", "Gold Rush", "Planet Money")])
        let miss = await PlayMediaIntentHandler().handle(intent: intent(search: search(type: .podcastEpisode, name: "Missing")))
        XCTAssertEqual(miss.code, .failure)
        XCTAssertTrue(target.performed.isEmpty)

        target.outcome = .failed
        let failed = await PlayMediaIntentHandler().handle(intent: intent(search: search(type: .podcastEpisode, name: "Gold Rush")))
        XCTAssertEqual(failed.code, .failure, "Siri must not claim playback that did not start")

        VoiceRuntime.provider = { nil }
        let none = await PlayMediaIntentHandler().handle(intent: intent(search: nil))
        XCTAssertEqual(none.code, .failure)
    }

    func testResolveReturnsOneResultAndNeverStartsPlayback() async throws {
        let target = install([try episode("a", "Gold Rush", "Planet Money")])
        let results = await PlayMediaIntentHandler().resolveMediaItems(for: intent(search: search(name: "Gold Rush")))
        XCTAssertEqual(results.count, 1)
        let missing = await PlayMediaIntentHandler().resolveMediaItems(for: intent(search: search(name: "Missing")))
        XCTAssertEqual(missing.count, 1)
        XCTAssertTrue(target.performed.isEmpty, "resolving must only look, never play")
    }

    func testResolveKeepsAnExplicitlyChosenEpisodeOverTheDefault() async throws {
        let a = try episode("a", "Gold Rush", "Planet Money", day: 9)
        let b = try episode("b", "Chips", "Planet Money", day: 1)
        _ = install([a, b])
        let item = INMediaItem(identifier: b.id.rawValue, title: b.title, type: .podcastEpisode, artwork: nil, artist: b.showTitle)
        let chosen = await PlayMediaIntentHandler.resolvedEpisode(for: intent(search: nil, items: [item]))
        XCTAssertEqual(chosen?.id, b.id, "the episode Siri chose, not the default next one")

        let gone = INMediaItem(identifier: "removed", title: "Gone", type: .podcastEpisode, artwork: nil, artist: nil)
        let fallback = await PlayMediaIntentHandler.resolvedEpisode(for: intent(search: search(name: "Gold Rush"), items: [gone]))
        XCTAssertEqual(fallback?.id, a.id, "an episode no longer on the phone falls back to the search")
    }

    // MARK: wiring

    func testAppDelegateRoutesPlayMediaIntentsToTheHandler() {
        let delegate = LibraryPushAppDelegate()
        XCTAssertTrue(delegate.application(UIApplication.shared, handlerFor: intent(search: nil)) is PlayMediaIntentHandler)
        XCTAssertNil(delegate.application(UIApplication.shared, handlerFor: INSearchForMediaIntent()))
    }

    /// The extension answers .handleInApp; the system then calls this, and the app plays the request.
    func testHandleInAppDeliveryPlaysTheEpisodeAndAnswersThroughTheCompletion() async throws {
        let chips = try episode("b", "Chips", "Planet Money")
        let target = install([try episode("a", "Gold Rush", "Planet Money"), chips])
        let delegate = LibraryPushAppDelegate()
        let response: INIntentResponse = await withCheckedContinuation { continuation in
            delegate.application(UIApplication.shared, handle: intent(search: search(type: .podcastEpisode, name: "Chips"))) {
                continuation.resume(returning: $0)
            }
        }
        XCTAssertEqual((response as? INPlayMediaIntentResponse)?.code, .success)
        XCTAssertEqual(target.performed, [.play(chips.id)])
        let other: INIntentResponse = await withCheckedContinuation { continuation in
            delegate.application(UIApplication.shared, handle: INSearchForMediaIntent()) { continuation.resume(returning: $0) }
        }
        XCTAssertEqual((other as? INPlayMediaIntentResponse)?.code, .failure, "an intent the app does not play is never reported as played")
    }
}

