import Foundation
import WiltedDomain
import WiltedLibrary

#if canImport(WiltedProducer)
import WiltedProducer

// MARK: - State source

/// What the model knows about playback that the store does not: the episode loaded in the
/// player, where it is, and whether it is playing.
struct WiltedMacPlaybackSample: Sendable, Equatable {
    var episodeID: ItemID
    var positionSeconds: Double
    var rate: Double
    var isPlaying: Bool
    var revisionID: RevisionID? = nil
}

/// `LibraryStateSource` over `LocalLibraryStore`, through the existing one-read library
/// snapshot. It only reads: the producer store stays the single writer (W-INV-005).
struct WiltedMacLocalLibraryStateSource: LibraryStateSource {
    static let summaryLimit = 2_000

    let store: LocalLibraryStore
    let deviceID: String
    /// Main-actor playback readout; nil when nothing podcast is loaded.
    let playback: @Sendable () async -> WiltedMacPlaybackSample?
    var localRequests: @Sendable () async -> [String: WiltedMacPreparationPublication.Request] = { [:] }

    init(store: LocalLibraryStore, deviceID: String,
         playback: @escaping @Sendable () async -> WiltedMacPlaybackSample?,
         localRequests: @escaping @Sendable () async -> [String: WiltedMacPreparationPublication.Request] = { [:] }) {
        self.store = store; self.deviceID = deviceID; self.playback = playback; self.localRequests = localRequests
    }

    func currentState() async throws -> LibraryStateSnapshot {
        let identity = try await store.podcastLibraryIdentitySnapshot(profile: .publication)
        let statuses = try await store.currentPreparationStatuses(
            for: identity.library.episodes.filter {
                identity.library.retiredAtByEpisode[$0.itemID] == nil
                    && identity.library.episodeDecisions[$0.itemID]?.decision == .keep
            }.map(\.itemID)
        )
        let requests = await localRequests()
        let filtered = statuses.filter { id, status in
            guard let local = requests[id.rawValue] else { return true }
            return !local.withdrawn && local.acknowledged && local.requestSequence == status.requestSequence
                && (local.attempt == nil || local.attempt?.attemptCount == status.attemptCount)
        }.mapValues { WiltedMacPreparationPublication.status($0) }
        return try Self.state(from: identity.library, queue: identity.library.podcastQueue.episodeIDs,
            playback: await playback(), deviceID: deviceID,
            associations: Self.associationMetadata(associations: identity.associations, states: identity.states),
            preparationStatuses: filtered.compactMapValues { $0 })
    }

    static func state(
        from snapshot: LocalLibraryStore.PodcastLibrarySnapshot, queue: [ItemID],
        playback: WiltedMacPlaybackSample?, deviceID: String, associations: [LibraryEpisodeAssociation] = [],
        preparationStatuses: [ItemID: LibraryPreparationStatus] = [:]
    ) throws -> LibraryStateSnapshot {
        let displayNames = Dictionary(snapshot.subscriptions.compactMap { subscription in
            subscription.displayName.map { (subscription.feedID, $0) }
        }, uniquingKeysWith: { first, _ in first })
        let feeds = snapshot.feeds.values.sorted { $0.itemID.rawValue < $1.itemID.rawValue }.map { feed in
            LibrarySource(
                id: feed.itemID, kind: .podcastFeed, title: displayNames[feed.itemID] ?? feed.title,
                locator: feed.canonicalURL.absoluteString, artworkRef: feed.artworkURL?.absoluteString
            )
        }
        let associationByID = Dictionary(associations.flatMap { association in
            association.memberIDs.map { ($0, association) }
        }, uniquingKeysWith: { first, _ in first })
        var episodes: [LibraryEntry] = []
        for episode in snapshot.episodes {
            let feed = snapshot.feeds[episode.feedID]
            episodes.append(try LibraryEntry(
                id: episode.itemID, kind: .podcastEpisode, sourceID: episode.feedID, title: episode.title,
                summary: String((episode.notes ?? "").prefix(summaryLimit)),
                publishedAt: (episode.publishedTime ?? episode.createdAt).date,
                durationSeconds: episode.durationSeconds,
                artworkRef: (episode.artworkURL ?? feed?.artworkURL)?.absoluteString,
                removal: removal(of: episode.itemID, in: snapshot),
                removedAt: snapshot.retiredAtByEpisode[episode.itemID]?.date,
                episodeAssociation: associationByID[episode.itemID],
                preparationStatus: preparationStatuses[episode.itemID],
                payload: try payloadBytes(PodcastEpisodePayload(
                    enclosureURL: episode.enclosureURL, feedURL: episode.feedURL, rssGUID: episode.rssGUID,
                    episodeLink: episode.episodeLink
                ))
            ))
        }
        let articles = try articleEntries(in: snapshot)
        let books = try audiobookEntries(in: snapshot)
        let published = episodes + articles + books
        let active = Set(published.filter { $0.removal == .none || $0.episodeAssociation?.isTerminal == false }.map(\.id))
        let known = Set(published.map(\.id))
        let listening = snapshot.listeningStates.values.filter { known.contains($0.episodeID) }
            .sorted { $0.episodeID.rawValue < $1.episodeID.rawValue }
            .map { ListeningRecord(itemID: $0.episodeID, completedAt: $0.completedAt?.date, updatedAt: $0.updatedAt.date, deviceID: deviceID) }
        return LibraryStateSnapshot(
            feeds: feeds + articleFeedSources(in: snapshot, displayNames: displayNames), episodes: published, queue: queue.filter(active.contains),
            listening: listening, currentPlayback: try position(of: playback, in: snapshot, known: known, deviceID: deviceID)
        )
    }

    static func associationMetadata(from store: LocalLibraryStore) async throws -> [LibraryEpisodeAssociation] {
        let identity = try await store.podcastLibraryIdentitySnapshot()
        return associationMetadata(associations: identity.associations, states: identity.states)
    }

    static func associationMetadata(associations: [PodcastEpisodeAssociation], states: [ItemID: PodcastEpisodeLogicalState]) -> [LibraryEpisodeAssociation] {
        var result: [LibraryEpisodeAssociation] = []
        for association in associations {
            guard let state = states[association.representativeID] else { continue }
            result.append(LibraryEpisodeAssociation(groupID: association.associationID,
                representativeID: association.representativeID, memberIDs: association.memberIDs,
                associationVersion: association.version, isTerminal: state.isTerminal,
                latestManualChoice: state.manualDecision.map { $0 == .keep ? .keep : .skip },
                manualDecidedAt: state.manualDecidedAt?.date,
                hasConflictingManualChoices: state.hasConflictingManualChoices))
        }
        return result
    }

    private static func articleFeedSources(
        in snapshot: LocalLibraryStore.PodcastLibrarySnapshot, displayNames: [ItemID: String]
    ) -> [LibrarySource] {
        snapshot.articleFeeds.sorted { $0.itemID.rawValue < $1.itemID.rawValue }.map {
            LibrarySource(id: $0.itemID, kind: .articleFeed, title: displayNames[$0.itemID] ?? $0.title, locator: $0.canonicalURL.absoluteString)
        }
    }

    /// Articles, each under the feed it was saved from, or under itself when added by hand or
    /// when its feed is no longer followed. The audio is offered through the media path.
    private static func articleEntries(in snapshot: LocalLibraryStore.PodcastLibrarySnapshot) throws -> [LibraryEntry] {
        let feeds = Set(snapshot.articleFeeds.map(\.itemID))
        return try snapshot.articles.map { article in
            let feedID = snapshot.feedIDByArticle[article.itemID].flatMap { feeds.contains($0) ? $0 : nil }
            let revision = snapshot.readyRevisions[article.itemID]?.revision
            return try LibraryEntry(
                id: article.itemID, kind: .article, sourceID: feedID ?? article.itemID, title: article.title,
                summary: String(article.source.prefix(summaryLimit)),
                publishedAt: (article.publishedTime ?? article.createdAt).date, durationSeconds: revision?.durationSeconds,
                removal: article.isDeleted ? .retired : .none
            )
        }
    }

    /// Audiobook volumes and morning reports (stored as one-volume audiobook rows, published as `report`). `LibraryEntry.publishedAt` is the ready revision's creation time, which
    /// is fixed once the volume is saved, so an unchanged volume never re-sends.
    private static func audiobookEntries(in snapshot: LocalLibraryStore.PodcastLibrarySnapshot) throws -> [LibraryEntry] {
        try snapshot.audiobooks.map { book in
            let payload = AudiobookPayload.build(
                title: book.title, author: book.author, durationSeconds: book.durationSeconds,
                chapters: book.chapters.map { AudiobookChapter(title: $0.title, startSeconds: $0.startSeconds) },
                sourceFormat: AudiobookPayload.SourceFormat(rawValue: book.sourceFormat) ?? .audio,
                volumeIndex: book.volumeIndex, volumeCount: book.volumeCount
            )
            return try LibraryEntry(
                id: book.itemID,
                kind: book.sourceFormat == LocalLibraryStore.reportSourceFormat ? .report : .audiobook, sourceID: book.itemID, title: book.title,
                summary: String((book.author ?? "").prefix(summaryLimit)),
                publishedAt: snapshot.readyRevisions[book.itemID]?.revision.createdAt.date ?? Date(timeIntervalSince1970: 0),
                durationSeconds: book.durationSeconds, removal: book.isRemoved ? .retired : .none,
                payload: try payload.encoded()
            )
        }
    }

    /// The payload with its keys in a fixed order. `JSONEncoder`'s default key order varies between
    /// encodes, and the differ compares payload bytes, so an unsorted payload re-sent every unchanged
    /// episode on every pass (Task 5.2 duplicate-send fix).
    static func payloadBytes(_ payload: PodcastEpisodePayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(payload)
    }

    private static func removal(of id: ItemID, in snapshot: LocalLibraryStore.PodcastLibrarySnapshot) -> LibraryRemoval {
        guard snapshot.retiredAtByEpisode[id] != nil else { return .none }
        return snapshot.removalKindByEpisode[id] == .dismissed ? .dismissed : .retired
    }

    /// Needs a revision to name; an episode with no prepared audio has none to publish.
    private static func position(
        of sample: WiltedMacPlaybackSample?, in snapshot: LocalLibraryStore.PodcastLibrarySnapshot,
        known: Set<ItemID>, deviceID: String
    ) throws -> DevicePlaybackPosition? {
        guard let sample, known.contains(sample.episodeID),
              let revision = sample.revisionID ?? snapshot.readyRevisions[sample.episodeID]?.revisionID
                ?? snapshot.listeningStates[sample.episodeID]?.lastRevisionID else { return nil }
        return try DevicePlaybackPosition(
            deviceID: deviceID, entryID: sample.episodeID, revision: revision,
            positionSeconds: max(0, sample.positionSeconds), rate: sample.rate > 0 ? sample.rate : 1,
            isPlaying: sample.isPlaying, epoch: 0
        )
    }
}

// MARK: - Ready audio

/// Podcast episodes' prepared audio (the existing media path) plus the ready revision of every
/// queued, live article and audiobook volume. Those are made by Wilted itself, so a ready
/// revision with its file on disk is all the proof they need; only reads.
struct WiltedMacLibraryReadyAudioSource: WiltedMacReadyAudioSource {
    let store: LocalLibraryStore
    private var podcasts: WiltedMacLocalReadyAudioSource { WiltedMacLocalReadyAudioSource(store: store) }

    func readyAudio(for entryID: ItemID) async throws -> WiltedMacReadyAudio? {
        if let audio = try await podcasts.readyAudio(for: entryID) { return audio }
        return try await ownAudio()[entryID]
    }

    func preparedQueuedAudio() async throws -> [ItemID: WiltedMacReadyAudio] {
        try await podcasts.preparedQueuedAudio().merging(ownAudio()) { podcast, _ in podcast }
    }

    func transcript(for entryID: ItemID, revisionID: RevisionID) async throws -> LibraryTranscript? {
        try await podcasts.transcript(for: entryID, revisionID: revisionID)
    }

    func transcripts(for revisions: [ItemID: RevisionID]) async throws -> [ItemID: LibraryTranscript] {
        try await podcasts.transcripts(for: revisions)
    }

    private func ownAudio() async throws -> [ItemID: WiltedMacReadyAudio] {
        let snapshot = try await store.podcastLibrarySnapshot(profile: .publication)
        let live = Set(snapshot.articles.filter { !$0.isDeleted }.map(\.itemID))
            .union(snapshot.audiobooks.filter { !$0.isRemoved }.map(\.itemID))
        var ready: [ItemID: WiltedMacReadyAudio] = [:]
        for id in snapshot.podcastQueue.episodeIDs where live.contains(id) {
            guard let stored = snapshot.readyRevisions[id], stored.mediaURL.isFileURL else { continue }
            let revision = stored.revision
            ready[id] = WiltedMacReadyAudio(
                revisionID: revision.revisionID, contentHash: revision.contentHash, byteCount: revision.byteCount,
                mediaType: revision.mediaType, durationSeconds: revision.durationSeconds, fileURL: stored.mediaURL,
                preparation: LibraryMediaPreparation(preparedAt: revision.createdAt)
            )
        }
        return ready
    }
}

#endif
