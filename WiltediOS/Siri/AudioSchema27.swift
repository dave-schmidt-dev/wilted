import AppIntents
import CoreSpotlight
import Foundation
import MediaIntents
import WiltedDomain
import WiltedLibrary

/// An iOS 27 audio-schema representation of a podcast feed in the phone's local Larder.
@available(iOS 27.0, *)
@AppEntity(schema: .audio.podcastShow)
struct WiltedPodcastShowEntity {
    static let defaultQuery = PodcastShowQuery()
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Podcast show")

    let id: String
    var title: String
    var showDescription: String?

    init(_ show: VoiceShow, subtitle: String? = nil) {
        id = show.id.rawValue
        title = show.title
        showDescription = subtitle ?? show.publisher
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: showDescription.map { "\($0)" })
    }

    struct PodcastShowQuery: EntityStringQuery, IntentValueQuery, IndexedEntityQuery {
        func entities(for identifiers: [String]) async throws -> [WiltedPodcastShowEntity] {
            let wanted = Set(identifiers)
            let shows = await VoiceShowLookup.shows().filter { wanted.contains($0.id.rawValue) }
            return VoiceShowLookup.entities(shows)
        }

        func entities(matching string: String) async throws -> [WiltedPodcastShowEntity] {
            let shows = await VoiceShowLookup.matching(string)
            return VoiceShowLookup.entities(shows)
        }

        func suggestedEntities() async throws -> [WiltedPodcastShowEntity] {
            VoiceShowLookup.entities(await VoiceShowLookup.shows())
        }

        func values(for input: AudioSearch) async throws -> [WiltedPodcastShowEntity] {
            let snapshot = await VoiceEpisodeLookup.snapshot()
            return VoiceShowLookup.entities(WiltedAudioSearch.shows(for: input.criteria, snapshot: snapshot))
        }

        func reindexEntities(for identifiers: [String], indexDescription _: CSSearchableIndexDescription) async throws {
            let wanted = Set(identifiers)
            let shows = await VoiceShowLookup.shows().filter { wanted.contains($0.id.rawValue) }
            try await CSSearchableIndex.default().indexAppEntities(VoiceShowLookup.entities(shows))
        }

        func reindexAllEntities(indexDescription _: CSSearchableIndexDescription) async throws {
            let shows = await VoiceShowLookup.shows()
            try await CSSearchableIndex.default().indexAppEntities(VoiceShowLookup.entities(shows))
        }
    }
}

/// A downloaded episode described using the iOS 27 podcast schema.
@available(iOS 27.0, *)
@AppEntity(schema: .audio.podcastEpisode)
struct WiltedPodcastEpisodeEntity {
    static let defaultQuery = PodcastEpisodeQuery()
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Podcast episode")

    let id: String
    var title: String
    var showName: String?
    var show: WiltedPodcastShowEntity?
    var releaseDate: Date?
    var duration: Double?

    init(_ episode: VoiceEpisode) {
        id = episode.id.rawValue
        title = episode.title
        showName = episode.showTitle.isEmpty ? nil : episode.showTitle
        show = episode.showID.flatMap { VoiceShowLookup.entity(id: $0.rawValue, title: episode.showTitle) }
        releaseDate = episode.publishedAt == .distantPast ? nil : episode.publishedAt
        duration = episode.duration
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: showName.map { "\($0)" })
    }

    struct PodcastEpisodeQuery: EntityStringQuery, IntentValueQuery, IndexedEntityQuery {
        func entities(for identifiers: [String]) async throws -> [WiltedPodcastEpisodeEntity] {
            let wanted = Set(identifiers)
            let episodes = await VoiceEpisodeLookup.episodes()
            return episodes.filter { wanted.contains($0.id.rawValue) }.map { WiltedPodcastEpisodeEntity($0) }
        }

        func entities(matching string: String) async throws -> [WiltedPodcastEpisodeEntity] {
            await VoiceEpisodeLookup.matching(string)
        }

        func suggestedEntities() async throws -> [WiltedPodcastEpisodeEntity] {
            await VoiceEpisodeLookup.episodes().prefix(25).map(WiltedPodcastEpisodeEntity.init)
        }

        func values(for input: AudioSearch) async throws -> [WiltedPodcastEpisodeEntity] {
            let snapshot = await VoiceEpisodeLookup.snapshot()
            return WiltedAudioSearch.episodes(for: input.criteria, snapshot: snapshot)
                .map(WiltedPodcastEpisodeEntity.init)
        }

        func reindexEntities(for identifiers: [String], indexDescription _: CSSearchableIndexDescription) async throws {
            let wanted = Set(identifiers)
            let episodes = await VoiceEpisodeLookup.episodes().filter { wanted.contains($0.id.rawValue) }
            try await CSSearchableIndex.default().indexAppEntities(episodes.map(WiltedPodcastEpisodeEntity.init))
        }

        func reindexAllEntities(indexDescription _: CSSearchableIndexDescription) async throws {
            let episodes = await VoiceEpisodeLookup.episodes()
            try await CSSearchableIndex.default().indexAppEntities(episodes.map(WiltedPodcastEpisodeEntity.init))
        }
    }
}

@available(iOS 27.0, *)
extension WiltedPodcastShowEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.displayName = title
        if let showDescription { attributes.contentDescription = showDescription }
        return attributes
    }
}

@available(iOS 27.0, *)
extension WiltedPodcastEpisodeEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.displayName = title
        if let showName { attributes.keywords = [showName] }
        if let releaseDate { attributes.contentCreationDate = releaseDate }
        return attributes
    }
}

/// The only playable audio kinds Wilted owns. A union result keeps same-title episodes distinct by ID.
@available(iOS 27.0, *)
@UnionValue
enum WiltedAudioItem {
    case podcastShow(WiltedPodcastShowEntity)
    case podcastEpisode(WiltedPodcastEpisodeEntity)

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Wilted audio" }
    static let caseDisplayRepresentations: [Cases: DisplayRepresentation] = [
        .podcastShow: "Podcast show", .podcastEpisode: "Podcast episode",
    ]
}

@available(iOS 27.0, *)
enum WiltedAudioSearch {
    static func shows(for criteria: AudioSearch.Criteria, snapshot: VoiceSnapshot) -> [VoiceShow] {
        switch criteria {
        case let .searchQuery(query):
            return matchingShows(query, snapshot: snapshot)
        case .unspecified:
            return []
        case let .url(urls):
            let canonical = Set(urls.map(\.absoluteString))
            return VoiceShowLookup.shows(in: snapshot).filter { show in
                show.feedURL.map { canonical.contains($0.absoluteString) } ?? false
            }
        @unknown default:
            return []
        }
    }

    static func episodes(for criteria: AudioSearch.Criteria, snapshot: VoiceSnapshot) -> [VoiceEpisode] {
        switch criteria {
        case let .searchQuery(query):
            return matchingEpisodes(query, in: snapshot.downloaded)
        case .unspecified:
            let plan = VoiceCommandPlanner.plan(.playNext(show: nil), snapshot: snapshot)
            guard case let .play(id) = plan.action else { return [] }
            return snapshot.downloaded.filter { $0.id == id }
        case let .url(urls):
            let canonical = Set(urls.map(\.absoluteString))
            return snapshot.downloaded.filter { episode in
                episode.episodeLink.map { canonical.contains($0.absoluteString) } ?? false
            }
        @unknown default:
            return []
        }
    }

    private static func matchingShows(_ query: String, snapshot: VoiceSnapshot) -> [VoiceShow] {
        let shows = VoiceShowLookup.shows(in: snapshot)
        switch VoiceShowMatcher.match(query, among: shows.map(\.title)) {
        case let .match(title): return shows.filter { VoiceShowMatcher.normalize($0.title) == VoiceShowMatcher.normalize(title) }
        case let .ambiguous(titles):
            let tied = Set(titles.map(VoiceShowMatcher.normalize))
            return shows.filter { tied.contains(VoiceShowMatcher.normalize($0.title)) }
        case .none: return []
        }
    }

    private static func matchingEpisodes(_ query: String, in episodes: [VoiceEpisode]) -> [VoiceEpisode] {
        switch VoiceShowMatcher.match(query, among: episodes.map(\.title)) {
        case let .match(title): return episodes.filter { VoiceShowMatcher.normalize($0.title) == VoiceShowMatcher.normalize(title) }
        case let .ambiguous(titles):
            let tied = Set(titles.map(VoiceShowMatcher.normalize))
            return episodes.filter { tied.contains(VoiceShowMatcher.normalize($0.title)) }
        case .none: return []
        }
    }
}

@available(iOS 27.0, *)
@AppEnum(schema: .audio.playbackAttributes)
enum WiltedPlaybackAttributes: String {
    case shuffle
    case `repeat`

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .shuffle: "Shuffle", .repeat: "Repeat",
    ]
}

@available(iOS 27.0, *)
@AppEnum(schema: .audio.queueInsertionLocation)
enum WiltedQueueInsertionLocation: String {
    case next
    case tail

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .next: "Play Next", .tail: "Play Last",
    ]
}

@available(iOS 27.0, *)
@AppEntity(schema: .audio.warmupAudioQueueResult)
struct WiltedWarmupAudioQueueResult: TransientAppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Warmed audio queue")
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "Warmed audio queue") }

    init() {}
}

@available(iOS 27.0, *)
@AppIntent(schema: .audio.playAudio)
struct WiltedPlayAudioIntent: AudioPlaybackIntent {
    var audioEntity: WiltedAudioItem
    var playbackAttributes: Set<WiltedPlaybackAttributes>
    var warmupAudioQueueResult: WiltedWarmupAudioQueueResult?
    var queueLocation: WiltedQueueInsertionLocation?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard playbackAttributes.isEmpty else {
            return .result(dialog: responseDialog(full: "Wilted doesn't support the requested playback option."))
        }
        guard queueLocation == nil else {
            let message = queueLocation == .next
                ? "Wilted can't queue this audio yet. Nothing started playing."
                : "Wilted can't add this audio to the end of the queue yet. Nothing started playing."
            return .result(dialog: responseDialog(full: message))
        }
        guard let target = await VoiceRuntime.target() else {
            return .result(dialog: responseDialog(full: VoiceCommandRunner.unavailableDialog))
        }
        let snapshot = await target.voiceSnapshot()
        switch audioEntity {
        case let .podcastEpisode(episode):
            guard let id = try? ItemID(rawValue: episode.id),
                  let selected = snapshot.downloaded.first(where: { $0.id == id }) else {
                return .result(dialog: responseDialog(full: "That downloaded episode is no longer available to play now."))
            }
            let command = VoiceCommandPlanner.plan(.playEpisodeByID(id), snapshot: snapshot)
            let line = await VoiceCommandRunner.run(command, on: target)
            let full = line == command.dialog ? "Playing \(selected.title), from \(selected.showTitle)." : line
            return .result(dialog: responseDialog(full: full, supporting: line))
        case let .podcastShow(show):
            guard let id = try? ItemID(rawValue: show.id),
                  let known = VoiceShowLookup.shows(in: snapshot).first(where: { $0.id == id }) else {
                return .result(dialog: responseDialog(full: "I can't find that show in the Larder."))
            }
            let episodes = snapshot.downloaded.filter { $0.showID == id }
            let selected = VoiceSnapshot(
                downloaded: episodes, knownShowTitles: [known.title], nowPlaying: snapshot.nowPlaying,
                resumeTarget: snapshot.resumeTarget, knownShows: [known])
            let plan = VoiceCommandPlanner.plan(.playLatest(show: nil), snapshot: selected)
            let line = await VoiceCommandRunner.run(plan, on: target)
            let full: String
            if line == plan.dialog, case let .play(episodeID) = plan.action,
               let latest = episodes.first(where: { $0.id == episodeID }) {
                full = "Playing \(latest.title), from \(known.title)."
            } else {
                full = line
            }
            return .result(dialog: responseDialog(full: full, supporting: line))
        }
    }

    private func responseDialog(full: String, supporting: String? = nil) -> IntentDialog {
        if systemContext.isVoiceOnly { return IntentDialog(stringLiteral: full) }
        let support = supporting ?? full
        return IntentDialog(
            full: LocalizedStringResource(stringLiteral: full),
            supporting: LocalizedStringResource(stringLiteral: support))
    }
}

@available(iOS 27.0, *)
private enum VoiceEpisodeLookup {
    @MainActor
    static func snapshot() async -> VoiceSnapshot {
        await VoiceRuntime.target()?.voiceSnapshot() ?? VoiceSnapshot(downloaded: [], knownShowTitles: [], nowPlaying: nil)
    }

    @MainActor
    static func episodes() async -> [VoiceEpisode] { await snapshot().downloaded }

    @MainActor
    static func matching(_ query: String) async -> [WiltedPodcastEpisodeEntity] {
        let snapshot = await snapshot()
        switch VoiceShowMatcher.match(query, among: snapshot.downloaded.map(\.title)) {
        case let .match(title): return snapshot.downloaded
            .filter { VoiceShowMatcher.normalize($0.title) == VoiceShowMatcher.normalize(title) }
            .map(WiltedPodcastEpisodeEntity.init)
        case let .ambiguous(titles):
            let tied = Set(titles.map(VoiceShowMatcher.normalize))
            return snapshot.downloaded.filter { tied.contains(VoiceShowMatcher.normalize($0.title)) }
                .map(WiltedPodcastEpisodeEntity.init)
        case .none: return []
        }
    }
}

@available(iOS 27.0, *)
private enum VoiceShowLookup {
    @MainActor
    static func shows() async -> [VoiceShow] { shows(in: await VoiceEpisodeLookup.snapshot()) }

    static func shows(in snapshot: VoiceSnapshot) -> [VoiceShow] {
        if !snapshot.knownShows.isEmpty {
            return snapshot.knownShows.sorted { $0.id.rawValue < $1.id.rawValue }
        }
        return Array(Set(snapshot.knownShowTitles)).sorted().compactMap { title in
            guard let id = try? ItemID(rawValue: title) else { return nil }
            return VoiceShow(id: id, title: title)
        }
    }

    static func entities(_ shows: [VoiceShow]) -> [WiltedPodcastShowEntity] {
        let groups = Dictionary(grouping: shows) { VoiceShowMatcher.normalize($0.title) }
        return shows.map { show in
            let duplicates = groups[VoiceShowMatcher.normalize(show.title)] ?? []
            let publisher = show.publisher?.trimmingCharacters(in: .whitespacesAndNewlines)
            let host = show.feedURL?.host
            guard duplicates.count > 1 else {
                return WiltedPodcastShowEntity(show, subtitle: publisher?.isEmpty == false ? publisher : host)
            }

            let publisherLabels = Set(duplicates.compactMap { nonEmpty($0.publisher)?.lowercased() })
            let hostLabels = Set(duplicates.compactMap { $0.feedURL?.host?.lowercased() })
            let distinctLabel: String
            if let publisher, !publisher.isEmpty, publisherLabels.count == duplicates.count {
                distinctLabel = publisher
            } else if let host, hostLabels.count == duplicates.count {
                distinctLabel = host
            } else if let publisher, !publisher.isEmpty, let host {
                distinctLabel = "\(publisher) · \(host)"
            } else if let host {
                distinctLabel = host
            } else if let publisher, !publisher.isEmpty {
                distinctLabel = publisher
            } else {
                distinctLabel = "Feed \(show.id.rawValue.suffix(6))"
            }
            return WiltedPodcastShowEntity(show, subtitle: distinctLabel)
        }
    }

    @MainActor
    static func matching(_ query: String) async -> [VoiceShow] {
        let shows = await shows()
        switch VoiceShowMatcher.match(query, among: shows.map(\.title)) {
        case let .match(title): return shows.filter { VoiceShowMatcher.normalize($0.title) == VoiceShowMatcher.normalize(title) }
        case let .ambiguous(titles):
            let tied = Set(titles.map(VoiceShowMatcher.normalize))
            return shows.filter { tied.contains(VoiceShowMatcher.normalize($0.title)) }
        case .none: return []
        }
    }

    static func entity(id: String, title: String) -> WiltedPodcastShowEntity? {
        guard let show = try? ItemID(rawValue: id) else { return nil }
        return WiltedPodcastShowEntity(VoiceShow(id: show, title: title))
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

}
