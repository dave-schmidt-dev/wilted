import AppIntents
import Combine
import CoreSpotlight
import Foundation
import OSLog
import WiltedDomain
import WiltedLibrary

private let indexLog = Logger(subsystem: "com.zerodelta.wilted", category: "SpotlightIndexer")

/// Episodes and shows go to Spotlight (and so to Siri's knowledge of the app) as indexed entities.
/// `IndexedEntity` and `CSSearchableIndex.indexAppEntities` are iOS 18 APIs; nothing here needs more.
extension EpisodeEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let set = defaultAttributeSet
        set.displayName = title
        if !showTitle.isEmpty { set.keywords = [showTitle] }
        return set
    }
}

extension ShowEntity: IndexedEntity {}

/// The part of Spotlight the indexer uses, so tests can record instead of touching the system index.
@MainActor
protocol EntityIndex: AnyObject {
    /// Each call returns whether the system applied it, so the indexer can repair a failed step.
    func index(episodes: [EpisodeEntity], shows: [ShowEntity]) async -> Bool
    func delete(episodeIDs: [String], showIDs: [String]) async -> Bool
    /// Every Wilted entity, including ones left by an earlier run.
    func deleteAll() async -> Bool
}

/// The app's default Spotlight index. Failures are logged and reported; `SpotlightIndexer` repairs
/// them with a full reset at its next sync.
final class SystemEntityIndex: EntityIndex, Sendable {
    // Not main-actor: `CSSearchableIndex` is not Sendable, so each call takes the shared index itself.
    nonisolated func index(episodes: [EpisodeEntity], shows: [ShowEntity]) async -> Bool {
        let index = CSSearchableIndex.default()
        do {
            if !episodes.isEmpty { try await index.indexAppEntities(episodes) }
            if !shows.isEmpty { try await index.indexAppEntities(shows) }
            return true
        } catch {
            indexLog.warning("indexing failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    nonisolated func delete(episodeIDs: [String], showIDs: [String]) async -> Bool {
        let index = CSSearchableIndex.default()
        do {
            if !episodeIDs.isEmpty { try await index.deleteAppEntities(identifiedBy: episodeIDs, ofType: EpisodeEntity.self) }
            if !showIDs.isEmpty { try await index.deleteAppEntities(identifiedBy: showIDs, ofType: ShowEntity.self) }
            return true
        } catch {
            indexLog.warning("index delete failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    nonisolated func deleteAll() async -> Bool {
        let index = CSSearchableIndex.default()
        do {
            try await index.deleteAppEntities(ofType: EpisodeEntity.self)
            try await index.deleteAppEntities(ofType: ShowEntity.self)
            return true
        } catch {
            indexLog.warning("index reset failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}

/// Keeps the Spotlight index equal to the episodes on the phone and their shows, like
/// `ShortcutParameterRefresher` does for the spoken phrases.
///
/// The first non-empty state resets the index and indexes everything, so entries left by an earlier run
/// (an episode removed while the app was not running) cannot linger. The very first empty state is
/// only the model not having loaded yet and does nothing; a second empty state before any episode
/// means the library loaded empty, so the index is reset. Every later state indexes what is new or
/// changed and deletes what left. A step the system rejects marks the index dirty, and the next
/// sync starts over with a full reset. Work runs one step at a time, in order.
@MainActor
final class SpotlightIndexer {
    private struct Entry: Equatable {
        let title: String
        let showTitle: String
    }

    private struct State {
        var episodes: [String: Entry]
        var shows: Set<String>
    }

    private var state: State?
    private var emptyStates = 0
    private var isDirty = false
    private var chain: Task<Void, Never>?
    private let index: any EntityIndex

    init(index: any EntityIndex = SystemEntityIndex()) {
        self.index = index
    }

    func sync(_ downloaded: [VoiceEpisode]) {
        var episodes: [String: Entry] = [:]
        for episode in downloaded { episodes[episode.id.rawValue] = Entry(title: episode.title, showTitle: episode.showTitle) }
        let shows = Set(downloaded.map(\.showTitle).filter { !$0.isEmpty })
        guard let previous = state, !isDirty else {
            if episodes.isEmpty, state == nil {
                emptyStates += 1
                guard emptyStates > 1 else { return }
            }
            isDirty = false
            state = State(episodes: episodes, shows: shows)
            let all = episodes.map { Self.entity($0.key, $0.value) }
            let showEntities = shows.map(ShowEntity.init(id:))
            enqueue { [index] in
                var ok = await index.deleteAll()
                ok = await index.index(episodes: all, shows: showEntities) && ok
                return ok
            }
            return
        }
        let changed = episodes.filter { previous.episodes[$0.key] != $0.value }
        let goneEpisodes = previous.episodes.keys.filter { episodes[$0] == nil }
        let newShows = shows.subtracting(previous.shows)
        let goneShows = previous.shows.subtracting(shows)
        state = State(episodes: episodes, shows: shows)
        guard !changed.isEmpty || !goneEpisodes.isEmpty || !newShows.isEmpty || !goneShows.isEmpty else { return }
        let toIndex = changed.map { Self.entity($0.key, $0.value) }
        enqueue { [index] in
            var ok = await index.delete(episodeIDs: Array(goneEpisodes), showIDs: Array(goneShows))
            ok = await index.index(episodes: toIndex, shows: newShows.map(ShowEntity.init(id:))) && ok
            return ok
        }
    }

    /// Waits for the queued index work; tests call it before asserting.
    func settle() async { await chain?.value }

    private func enqueue(_ work: @escaping @MainActor () async -> Bool) {
        let prior = chain
        chain = Task {
            await prior?.value
            if await !work() { isDirty = true }
        }
    }

    private static func entity(_ id: String, _ entry: Entry) -> EpisodeEntity {
        // The id came from an `ItemID` already, so it is valid.
        EpisodeEntity(VoiceEpisode(id: try! ItemID(rawValue: id), title: entry.title, showTitle: entry.showTitle))
    }

    /// Watches the model for the life of the returned subscription.
    static func observe(_ model: LibraryAppModel, indexer: SpotlightIndexer = SpotlightIndexer()) -> AnyCancellable {
        model.$queued.combineLatest(model.$media)
            .map { rows, media in
                rows.filter { media[$0.id] == .onPhone }.map { VoiceEpisode(id: $0.id, title: $0.title, showTitle: $0.showTitle) }
            }
            .sink { episodes in MainActor.assumeIsolated { indexer.sync(episodes) } }
    }
}
