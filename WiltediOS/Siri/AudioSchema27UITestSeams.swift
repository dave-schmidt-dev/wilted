#if DEBUG
import AppIntents
import Foundation
import MediaIntents

/// Unlisted App Intents test seams. The iOS 27 UI test target invokes them out-of-process.
@available(iOS 27.0, *)
struct WiltedSiriFixtureSetupIntent: AppIntent {
    static let title: LocalizedStringResource = "Prepare Siri Fixture"
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let stack = LibraryUITestFixture.stack, stack.scenario == .siri else {
            return .result(value: "unavailable")
        }
        await stack.prepareSiriTest()
        return .result(value: "ready")
    }
}

@available(iOS 27.0, *)
struct WiltedSiriFixtureLoadCompletionIntent: AppIntent {
    static let title: LocalizedStringResource = "Load Siri Completion Fixture"
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let stack = LibraryUITestFixture.stack, stack.scenario == .siri else {
            return .result(value: "unavailable")
        }
        return .result(value: await stack.loadSiriCompletionEpisode())
    }
}

@available(iOS 27.0, *)
struct WiltedSiriFixtureProbeIntent: AppIntent {
    static let title: LocalizedStringResource = "Read Siri Fixture State"
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let stack = LibraryUITestFixture.stack, stack.scenario == .siri else {
            return .result(value: "{}")
        }
        return .result(value: stack.siriProbeJSON())
    }
}

/// Exercises the production typed value-query path that AppIntentsTesting cannot encode directly.
@available(iOS 27.0, *)
struct WiltedSiriFixtureAudioSearchProbeIntent: AppIntent {
    static let title: LocalizedStringResource = "Inspect Siri Audio Search"
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let stack = LibraryUITestFixture.stack, stack.scenario == .siri else {
            return .result(value: "{}")
        }
        let showSearch = try await WiltedPodcastShowEntity.PodcastShowQuery().values(
            for: AudioSearch(criteria: .searchQuery("Twin Show")))
        let episodeSearch = try await WiltedPodcastEpisodeEntity.PodcastEpisodeQuery().values(
            for: AudioSearch(criteria: .searchQuery("Twin Episode")))
        let showURL = URL(string: "https://a.example.com/feed.xml")!
        let episodeURL = URL(string: "https://episodes.example.com/siri-twin-a-new")!
        let showByURL = try await WiltedPodcastShowEntity.PodcastShowQuery().values(
            for: AudioSearch(criteria: .url([showURL])))
        let episodeByURL = try await WiltedPodcastEpisodeEntity.PodcastEpisodeQuery().values(
            for: AudioSearch(criteria: .url([episodeURL])))
        let defaultEpisodes = try await WiltedPodcastEpisodeEntity.PodcastEpisodeQuery().values(
            for: AudioSearch(criteria: .unspecified))
        let defaultShows = try await WiltedPodcastShowEntity.PodcastShowQuery().values(
            for: AudioSearch(criteria: .unspecified))
        let report: [String: Any] = [
            "showQueryIDs": showSearch.map(\.id).sorted(),
            "showQuerySubtitles": showSearch.compactMap(\.showDescription).sorted(),
            "episodeQueryIDs": episodeSearch.map(\.id).sorted(),
            "episodeQueryShowNames": episodeSearch.compactMap(\.showName).sorted(),
            "showURLIDs": showByURL.map(\.id).sorted(),
            "episodeURLIDs": episodeByURL.map(\.id).sorted(),
            "unspecifiedEpisodeCount": defaultEpisodes.count,
            "unspecifiedShowCount": defaultShows.count,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return .result(value: "{}") }
        return .result(value: text)
    }
}
#endif
