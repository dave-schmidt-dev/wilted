#if DEBUG
import AppIntents
import Foundation
import MediaPlayer
import WiltedDomain
import WiltedLibrary
import WiltedPlayback

@MainActor
extension LibraryUITestFixture.Stack {
    /// Prepares only local state consumed by the system App Intents runner.
    func prepareSiriTest() async {
        guard scenario == .siri else { return }
        await seed()
        await model.loadLocalState()
    }

    /// Starts the seeded completion episode through the normal voice target path.
    func loadSiriCompletionEpisode() async -> String {
        await prepareSiriTest()
        guard let id = try? ItemID(rawValue: LibraryUITestFixture.siriCompletionEpisodeID),
              let target = await VoiceRuntime.target() else { return "unavailable" }
        return String(describing: await target.perform(.play(id)))
    }

    /// Reads serialized phone state after the test-only setup and production intents run.
    func siriProbeJSON() -> String {
        let outboxOwner: String?
        let markDoneIDs: [String]
        switch LibraryIntentOutbox(url: outboxURL).load() {
        case let .saved(saved):
            outboxOwner = saved.ownerToken
            markDoneIDs = saved.decisions.compactMap { decision in
                guard case let .markDone(entryID) = decision.intent.action else { return nil }
                return entryID.rawValue
            }.sorted()
        case .empty, .unreadable:
            outboxOwner = nil
            markDoneIDs = []
        }
        let finished = LibraryFinishedHereStore(url: finishedHereURL).load()
        let appEntities = nowPlaying.appEntityIdentifiers().map {
            ["type": String(reflecting: $0.entityType), "id": $0.identifier]
        }
        var mediaPlayerEntityCount = 0
        if #available(iOS 27.0, *) {
            let info = ListenerNowPlayingInfo(
                title: "Fixture episode", duration: 1, position: 0, rate: 1, defaultRate: 1,
                appEntityIdentifiers: nowPlaying.appEntityIdentifiers())
            let payload = MediaPlayerNowPlaying.payload(for: info)
            mediaPlayerEntityCount = (payload[MPNowPlayingInfoPropertyAppEntityIdentifiers] as? [MPAppEntityIdentifier])?.count ?? 0
        }
        let report: [String: Any] = [
            "nowPlayingID": player.item.map { $0.entryID.rawValue as Any } ?? NSNull(),
            "nowPlayingEntities": appEntities,
            "mediaPlayerEntityCount": mediaPlayerEntityCount,
            "outboxOwner": outboxOwner.map { $0 as Any } ?? NSNull(),
            "outboxMarkDoneIDs": markDoneIDs,
            "finishedOwner": finished.ownerToken.map { $0 as Any } ?? NSNull(),
            "finishedHereIDs": finished.entries.keys.map(\.rawValue).sorted(),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    static func siriLibraryChanges() throws -> [LibraryChange] {
        let shows: [(id: String, title: String, publisher: String, feedURL: String)] = [
            ("siri-show-twin-a", "Twin Show", "Twin Audio A", "https://a.example.com/feed.xml"),
            ("siri-show-twin-b", "Twin Show", "Twin Audio B", "https://b.example.com/feed.xml"),
            ("siri-show-second-twin", "Second Twin Show", "Second Twin Audio", "https://second.example.com/feed.xml"),
            ("siri-show-latest", "Latest Show", "Latest Audio", "https://latest.example.com/feed.xml"),
            ("siri-completion-show", "Completion Show", "Completion Audio", "https://completion.example.com/feed.xml"),
        ]
        var changes = try shows.map { show in
            LibraryChange.source(LibrarySource(
                id: try ItemID(rawValue: show.id), kind: .podcastFeed, title: show.title,
                publisher: show.publisher, locator: show.feedURL))
        }
        let episodes: [(id: String, showID: String, title: String, published: Double, order: Double)] = [
            ("siri-twin-a-old", "siri-show-twin-a", "A Older Episode", 1_700_000_000, 0),
            ("siri-twin-a-new", "siri-show-twin-a", "A Newest Episode", 1_700_000_100, 1),
            ("siri-twin-b-episode", "siri-show-twin-b", "Twin Episode", 1_700_000_200, 2),
            ("siri-twin-c-episode", "siri-show-second-twin", "Twin Episode", 1_700_000_300, 3),
            ("siri-latest-old", "siri-show-latest", "Older Report", 1_700_000_400, 4),
            ("siri-latest-new", "siri-show-latest", "Newest Report", 1_700_000_500, 5),
            (LibraryUITestFixture.siriCompletionEpisodeID, "siri-completion-show", "Completion Episode", 1_700_000_600, 6),
        ]
        for episode in episodes {
            let id = try ItemID(rawValue: episode.id)
            let showID = try ItemID(rawValue: episode.showID)
            guard let feedString = shows.first(where: { $0.id == episode.showID })?.feedURL,
                  let feedURL = URL(string: feedString),
                  let episodeLink = URL(string: "https://episodes.example.com/\(episode.id)"),
                  let enclosureURL = URL(string: "https://audio.example.com/\(episode.id).mp3") else {
                throw URLError(.badURL)
            }
            let payload = try JSONEncoder().encode(PodcastEpisodePayload(
                enclosureURL: enclosureURL, feedURL: feedURL, rssGUID: episode.id, episodeLink: episodeLink))
            changes.append(.entry(try LibraryEntry(
                id: id, kind: .podcastEpisode, sourceID: showID, title: episode.title,
                summary: "A local Siri fixture episode.", publishedAt: Date(timeIntervalSince1970: episode.published),
                durationSeconds: LibraryUITestEngine.length, payload: payload)))
            changes.append(.slot(try QueueSlot(entryID: id, sortKey: episode.order)))
        }
        return changes
    }
}
#endif
