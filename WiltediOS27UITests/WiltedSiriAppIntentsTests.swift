import AppIntentsTesting
import XCTest

/// Runs the iOS 27 audio schema through Apple's out-of-process App Intents test runner.
@available(iOS 27.0, *)
@MainActor
final class WiltedSiriAppIntentsTests: XCTestCase {
    private static let appBundleIdentifier = "com.zerodelta.wilted.ios"
    private static let fixtureMarker = "wilted-library-root-fixture"

    private struct FixtureProbe: Decodable {
        let nowPlayingID: String?
        let nowPlayingEntities: [NowPlayingEntity]?
        let mediaPlayerEntityCount: Int?
        let outboxOwner: String?
        let outboxMarkDoneIDs: [String]
        let finishedOwner: String?
        let finishedHereIDs: [String]
    }

    private struct NowPlayingEntity: Decodable {
        let type: String
        let id: String
    }

    private struct AudioSearchProbe: Decodable {
        let showQueryIDs: [String]
        let showQuerySubtitles: [String]
        let episodeQueryIDs: [String]
        let episodeQueryShowNames: [String]
        let showURLIDs: [String]
        let episodeURLIDs: [String]
        let unspecifiedEpisodeCount: Int
        let unspecifiedShowCount: Int
    }

    func testAudioSchemaQueryAndPlaybackThroughSystemRunner() async throws {
        let (_, definitions) = try await launchSiriFixture()
        let typedSearch = try await audioSearchProbe(using: definitions)
        XCTAssertEqual(typedSearch.showQueryIDs, ["siri-show-twin-a", "siri-show-twin-b"])
        XCTAssertEqual(typedSearch.showQuerySubtitles, ["Twin Audio A", "Twin Audio B"])
        XCTAssertEqual(typedSearch.episodeQueryIDs, ["siri-twin-b-episode", "siri-twin-c-episode"])
        XCTAssertEqual(typedSearch.episodeQueryShowNames, ["Second Twin Show", "Twin Show"])
        XCTAssertEqual(typedSearch.showURLIDs, ["siri-show-twin-a"])
        XCTAssertEqual(typedSearch.episodeURLIDs, ["siri-twin-a-new"])
        XCTAssertEqual(typedSearch.unspecifiedEpisodeCount, 1)
        XCTAssertEqual(typedSearch.unspecifiedShowCount, 0)

        let result = try await definitions.entities["WiltedPodcastEpisodeEntity"].entities(matching: "A Newest Episode")

        XCTAssertEqual(result.count, 1)
        let episodeID = result[0].identifier.instanceIdentifier
        XCTAssertEqual(episodeID, "siri-twin-a-new")
        let episode = result[0]

        let beforePlayback = try await probe(using: definitions)
        XCTAssertNil(beforePlayback.nowPlayingID, "querying the registered audio schema must not start playback")

        try await play(episode, using: definitions)

        let afterPlayback = try await probe(using: definitions)
        XCTAssertEqual(afterPlayback.nowPlayingID, episodeID, "PlayAudio must receive and play the query result")
        let nowPlayingEntities = try XCTUnwrap(afterPlayback.nowPlayingEntities)
        XCTAssertEqual(Set(nowPlayingEntities.map(\.id)), ["siri-twin-a-new", "siri-show-twin-a"])
        let entityTypes = nowPlayingEntities.map(\.type)
        XCTAssertTrue(entityTypes.contains { $0.hasSuffix("WiltedPodcastEpisodeEntity") })
        XCTAssertTrue(entityTypes.contains { $0.hasSuffix("WiltedPodcastShowEntity") })
        XCTAssertEqual(afterPlayback.mediaPlayerEntityCount, 2,
                       "MediaPlayer Now Playing must publish both episode and show entity identifiers")
    }

    func testAmbiguousShowWaitsForChosenEntityAndPlaysLatest() async throws {
        let (_, definitions) = try await launchSiriFixture()
        let result = try await definitions.entities["WiltedPodcastShowEntity"].entities(matching: "Twin Show")

        XCTAssertEqual(result.count, 2, "both same-named shows must remain available for system disambiguation")
        let identifiers = result.map { $0.identifier.instanceIdentifier }
        XCTAssertEqual(Set(identifiers), ["siri-show-twin-a", "siri-show-twin-b"])

        let beforeSelection = try await probe(using: definitions)
        XCTAssertNil(beforeSelection.nowPlayingID, "an ambiguous query cannot play before the system/user selects a show")

        let selectedIndex = try XCTUnwrap(identifiers.firstIndex(of: "siri-show-twin-a"))
        let selectedShow = result[selectedIndex]
        try await play(selectedShow, using: definitions)

        let afterSelection = try await probe(using: definitions)
        XCTAssertEqual(afterSelection.nowPlayingID, "siri-twin-a-new", "choosing the first Twin Show must play its newest downloaded episode")
    }

    func testDuplicateEpisodeTitlesAreDisambiguatedByShow() async throws {
        let (_, definitions) = try await launchSiriFixture()
        let result = try await definitions.entities["WiltedPodcastEpisodeEntity"].entities(matching: "Twin Episode")

        XCTAssertEqual(result.count, 2, "same-title episodes from different shows must not collapse")
        let identifiers = result.map { $0.identifier.instanceIdentifier }
        var showNames: [String?] = []
        for index in 0..<result.count {
            let showName: String? = try result[index].showName
            showNames.append(showName)
        }
        XCTAssertEqual(Set(identifiers), ["siri-twin-b-episode", "siri-twin-c-episode"])
        XCTAssertEqual(Set(showNames.compactMap { $0 }), ["Twin Show", "Second Twin Show"])

        let beforeSelection = try await probe(using: definitions)
        XCTAssertNil(beforeSelection.nowPlayingID, "episode search is only a candidate list")

        let selectedIndex = try XCTUnwrap(identifiers.firstIndex(of: "siri-twin-c-episode"))
        let selectedEpisode = result[selectedIndex]
        try await play(selectedEpisode, using: definitions)

        let afterSelection = try await probe(using: definitions)
        XCTAssertEqual(afterSelection.nowPlayingID, "siri-twin-c-episode", "the chosen show-specific episode must be the one played")
    }

    func testQueueLocationNextDoesNotStartPlayback() async throws {
        let (_, definitions) = try await launchSiriFixture()
        let episodeResults = try await definitions.entities["WiltedPodcastEpisodeEntity"].entities(matching: "A Newest Episode")
        XCTAssertEqual(episodeResults.count, 1)
        let episode = episodeResults[0]
        let showResults = try await definitions.entities["WiltedPodcastShowEntity"].entities(matching: "Latest Show")
        XCTAssertEqual(showResults.count, 1)
        let show = showResults[0]

        let beforeRequest = try await probe(using: definitions)
        XCTAssertNil(beforeRequest.nowPlayingID)

        try await requestNext(episode, using: definitions)
        let afterEpisodeRequest = try await probe(using: definitions)
        XCTAssertNil(afterEpisodeRequest.nowPlayingID, "Play Next for a specific episode must not start playback")

        try await requestNext(show, using: definitions)
        let afterShowRequest = try await probe(using: definitions)
        XCTAssertNil(afterShowRequest.nowPlayingID, "Play Next for a podcast show must not start playback")

    }

    func testMarkCompletedIntentPersistsOutboxBeforeTransportAck() async throws {
        let (_, definitions) = try await launchSiriFixture()
        let load = definitions.intents["WiltedSiriFixtureLoadCompletionIntent"].makeIntent()
        let loadResult = try await load.run()
        let loadValue: String = try loadResult.value
        XCTAssertEqual(loadValue, "done")

        let beforeCompletion = try await probe(using: definitions)
        XCTAssertEqual(beforeCompletion.nowPlayingID, "siri-completion-episode")
        XCTAssertTrue(beforeCompletion.outboxMarkDoneIDs.isEmpty)

        let markCompleted = definitions.intents["MarkCompletedIntent"].makeIntent()
        _ = try await markCompleted.run()

        let afterCompletion = try await probe(using: definitions)
        XCTAssertEqual(afterCompletion.outboxOwner, "fixture-owner")
        XCTAssertEqual(afterCompletion.outboxMarkDoneIDs, ["siri-completion-episode"],
                       "the mark-done intent must be durable while the fixture transport rejects delivery")
        XCTAssertEqual(afterCompletion.finishedOwner, "fixture-owner")
        XCTAssertEqual(afterCompletion.finishedHereIDs, ["siri-completion-episode"],
                       "the phone keeps the episode finished locally until the Mac acknowledges it")
    }

    private func launchSiriFixture() async throws -> (XCUIApplication, IntentDefinitions) {
        let app = XCUIApplication()
        app.launchArguments = [
            "--wilted-library-root-fixture",
            "--wilted-library-root-scenario=siri",
        ]
        app.launch()

        let marker = app.descendants(matching: .any)[Self.fixtureMarker]
        XCTAssertTrue(marker.waitForExistence(timeout: 20), "the isolated Larder fixture must finish launching")

        let definitions = IntentDefinitions(bundleIdentifier: Self.appBundleIdentifier)
        // AppIntentsTesting 27.2 can execute the registered entity string queries out-of-process,
        // but AudioSearch itself isn't IntentValueConvertible, so its typed value-query payload
        // isn't expressible through this runner. Keep the schema value-query registration check here.
        for queryName in ["WiltedPodcastShowEntity.PodcastShowQuery", "WiltedPodcastEpisodeEntity.PodcastEpisodeQuery"] {
            XCTAssertEqual(definitions.valueQueries[queryName].queryIdentifier, queryName,
                           "the schema value query must be registered with the app")
        }
        let setup = definitions.intents["WiltedSiriFixtureSetupIntent"].makeIntent()
        let setupResult = try await setup.run()
        let setupValue: String = try setupResult.value
        XCTAssertEqual(setupValue, "ready", "the system test runner must attach to the seeded fixture")
        XCTAssertEqual(marker.value as? String, "0", "the fixture must not construct a live CloudKit transport")
        return (app, definitions)
    }

    private func play(_ entity: AnyAppEntity, using definitions: IntentDefinitions) async throws {
        let intent = definitions.intents["WiltedPlayAudioIntent"].makeIntent(
            audioEntity: entity,
            playbackAttributes: Set<String>())
        _ = try await intent.run()
    }

    private func requestNext(_ entity: AnyAppEntity, using definitions: IntentDefinitions) async throws {
        var intent = definitions.intents["WiltedPlayAudioIntent"].makeIntent(
            audioEntity: entity,
            playbackAttributes: Set<String>())
        intent.queueLocation = definitions.enums["WiltedQueueInsertionLocation"].makeCase("next")
        _ = try await intent.run()
    }

    private func probe(using definitions: IntentDefinitions) async throws -> FixtureProbe {
        let intent = definitions.intents["WiltedSiriFixtureProbeIntent"].makeIntent()
        let result = try await intent.run()
        let json: String = try result.value
        return try JSONDecoder().decode(FixtureProbe.self, from: Data(json.utf8))
    }

    private func audioSearchProbe(using definitions: IntentDefinitions) async throws -> AudioSearchProbe {
        let intent = definitions.intents["WiltedSiriFixtureAudioSearchProbeIntent"].makeIntent()
        let result = try await intent.run()
        let json: String = try result.value
        return try JSONDecoder().decode(AudioSearchProbe.self, from: Data(json.utf8))
    }
}
