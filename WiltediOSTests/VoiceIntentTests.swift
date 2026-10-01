import AppIntents
import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltediOS

/// The intent shells and entity queries against a recording target: what Siri hands in becomes the
/// right command, and the planner's line is what Siri speaks.
@MainActor
final class VoiceIntentTests: XCTestCase {
    private var savedProvider: (@MainActor () async -> (any VoiceCommandTarget)?)!

    override func setUp() async throws {
        savedProvider = VoiceRuntime.provider
    }

    override func tearDown() async throws {
        VoiceRuntime.provider = savedProvider
    }

    private func episode(_ raw: String, _ title: String, _ show: String, day: Double = 0) throws -> VoiceEpisode {
        VoiceEpisode(
            id: try ItemID(rawValue: raw), title: title, showTitle: show,
            publishedAt: Date(timeIntervalSince1970: day * 86_400))
    }

    private func install(_ episodes: [VoiceEpisode], playing: VoiceEpisode? = nil) -> RecordingTarget {
        let target = RecordingTarget(snapshot: VoiceSnapshot(
            downloaded: episodes, knownShowTitles: Array(Set(episodes.map(\.showTitle))).sorted(),
            nowPlaying: playing.map { VoiceNowPlaying(episode: $0, isPlaying: true, canMarkCompleted: false) }))
        VoiceRuntime.provider = { target }
        return target
    }

    private func fixtures() throws -> [VoiceEpisode] {
        [try episode("a", "Gold Rush", "Planet Money", day: 1),
         try episode("b", "Chips", "Planet Money", day: 9),
         try episode("c", "Tide Pools", "Short Wave", day: 5)]
    }

    func testPlayEpisodeIntentPlaysTheChosenEpisodeScopedToItsShow() async throws {
        let episodes = try fixtures()
        let target = install(episodes)
        let intent = PlayEpisodeIntent()
        intent.episode = EpisodeEntity(episodes[2])
        _ = try await intent.perform()
        XCTAssertEqual(target.performed, [.play(episodes[2].id)])
    }

    func testPlayEpisodeIntentKeepsEqualTitlesApart() async throws {
        let twins = [try episode("x", "Rerun", "Show"), try episode("y", "Rerun", "Show")]
        let target = install(twins)
        let intent = PlayEpisodeIntent()
        intent.episode = EpisodeEntity(twins[1])
        _ = try await intent.perform()
        XCTAssertEqual(target.performed, [.play(twins[1].id)], "the second twin, not the first title match")
    }

    func testAmbiguousSpokenTitleOffersEveryTiedEpisode() async throws {
        _ = install([
            try episode("a", "Gold Rush", "Planet Money"), try episode("b", "Gold Rush", "Short Wave"),
            try episode("c", "Gold Rush Redux", "Third Show"),
        ])
        let found = try await EpisodeEntityQuery().entities(matching: "rush")
        XCTAssertEqual(found.map(\.id), ["a", "b", "c"])
    }

    func testPlayLatestIntentPicksTheNewestOfTheGivenShowOrOverall() async throws {
        let target = install(try fixtures())
        let intent = PlayLatestIntent()
        _ = try await intent.perform()
        intent.show = ShowEntity(id: "Short Wave")
        _ = try await intent.perform()
        XCTAssertEqual(target.performed, [.play(try ItemID(rawValue: "b")), .play(try ItemID(rawValue: "c"))])
    }

    func testEpisodeQueryMatchesSpokenTitlesAndResolvesIdentifiers() async throws {
        let episodes = try fixtures()
        _ = install(episodes)
        let query = EpisodeEntityQuery()
        let byName = try await query.entities(matching: "tide pool")
        XCTAssertEqual(byName.map(\.id), ["c"])
        let none = try await query.entities(matching: "quantum")
        XCTAssertTrue(none.isEmpty)
        let byID = try await query.entities(for: ["b", "zzz"])
        XCTAssertEqual(byID.map(\.title), ["Chips"])
        let suggested = try await query.suggestedEntities()
        XCTAssertEqual(suggested.map(\.id), ["a", "b", "c"])
    }

    func testEpisodeQueryWithNoTargetReturnsNothing() async throws {
        VoiceRuntime.provider = { nil }
        let query = EpisodeEntityQuery()
        let found = try await query.entities(matching: "anything")
        XCTAssertTrue(found.isEmpty)
    }
}
