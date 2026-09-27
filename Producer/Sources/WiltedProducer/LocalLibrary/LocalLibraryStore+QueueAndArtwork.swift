import CryptoKit
import Foundation
import SwiftData
import WiltedDomain
import WiltedSync

extension LocalLibraryStore {
    public func save(artwork: PodcastArtwork) throws {
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastArtworkRecord>())
        if let existing = records.first(where: { $0.id == artwork.id }) {
            existing.ownerID = artwork.ownerID.rawValue; existing.remoteURL = artwork.remoteURL?.absoluteString; existing.localURL = artwork.localURL?.absoluteString
            existing.contentHash = artwork.contentHash; existing.byteCount = artwork.byteCount; existing.updatedAt = artwork.updatedAt.date
        } else { context.insert(LocalLibrarySchemaV6Models.PodcastArtworkRecord(artwork)) }
        try context.save()
    }

    public func save(artworkAsset artwork: PodcastArtwork) throws { try save(artwork: artwork) }

    public func artwork(for id: String) throws -> PodcastArtwork? {
        let context = ModelContext(container)
        guard let record = try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastArtworkRecord>()).first(where: { $0.id == id }), let ownerID = try? ItemID(rawValue: record.ownerID) else { return nil }
        return try PodcastArtwork(id: record.id, ownerID: ownerID, remoteURL: record.remoteURL.flatMap(URL.init), localURL: record.localURL.flatMap(URL.init), contentHash: record.contentHash, byteCount: record.byteCount, updatedAt: Timestamp(record.updatedAt))
    }

    public func save(queueEntry: PodcastQueueEntry) throws {
        var state = try podcastQueueState()
        var ids = state.episodeIDs.filter { $0 != queueEntry.episodeID }
        ids.insert(queueEntry.episodeID, at: max(0, min(queueEntry.position, ids.count)))
        state = try PodcastQueueState(episodeIDs: ids, currentEpisodeID: state.currentEpisodeID)
        try replacePodcastQueue(state, addedAt: queueEntry.addedAt)
    }

    public func queue() throws -> [PodcastQueueEntry] {
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastQueueRecord>())
            .sorted(by: Self.podcastQueueRecordPrecedes)
        return records.enumerated().compactMap { position, record in
            guard let episodeID = try? ItemID(rawValue: record.episodeID) else { return nil }
            return try? PodcastQueueEntry(episodeID: episodeID, position: position, addedAt: Timestamp(record.addedAt))
        }
    }

    public func upNext() throws -> [PodcastQueueEntry] { try queue() }

    public func save(upNext entry: PodcastQueueEntry) throws { try save(queueEntry: entry) }

    /// Replaces order and current identity in one context save. Public queue
    /// positions are always decoded to the contiguous range `0..<count`.
    public func replacePodcastQueue(_ state: PodcastQueueState, addedAt: Timestamp = Timestamp(Date())) throws {
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastQueueRecord>())
        let existingDates = Dictionary(uniqueKeysWithValues: records.map { ($0.episodeID, $0.addedAt) })
        for record in records { context.delete(record) }
        for (position, episodeID) in state.episodeIDs.enumerated() {
            let storedPosition = position + (episodeID == state.currentEpisodeID ? Self.podcastCurrentPositionOffset : 0)
            let entry = try PodcastQueueEntry(
                episodeID: episodeID,
                position: storedPosition,
                addedAt: Timestamp(existingDates[episodeID.rawValue] ?? addedAt.date)
            )
            context.insert(LocalLibrarySchemaV6Models.PodcastQueueRecord(entry))
        }
        try context.save()
    }

    public func podcastQueueState() throws -> PodcastQueueState {
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastQueueRecord>())
            .sorted(by: Self.podcastQueueRecordPrecedes)
        let ids = records.compactMap { try? ItemID(rawValue: $0.episodeID) }
        let current = records.first(where: { $0.position >= Self.podcastCurrentPositionOffset })
            .flatMap { try? ItemID(rawValue: $0.episodeID) }
        return try PodcastQueueState(episodeIDs: ids, currentEpisodeID: current)
    }

    private static func decodedPodcastQueuePosition(_ position: Int) -> Int {
        position >= podcastCurrentPositionOffset ? position - podcastCurrentPositionOffset : position
    }

    /// The one total order every public queue read uses, so `queue()` and
    /// `podcastQueueState()` cannot disagree about stored order. Decoded position
    /// first, then episode ID: storage can hold two rows at the same decoded
    /// position, and without the second key their relative order would be
    /// whatever the sort happened to produce.
    private static func podcastQueueRecordPrecedes(
        _ lhs: LocalLibrarySchemaV6Models.PodcastQueueRecord,
        _ rhs: LocalLibrarySchemaV6Models.PodcastQueueRecord
    ) -> Bool {
        let lhsPosition = decodedPodcastQueuePosition(lhs.position)
        let rhsPosition = decodedPodcastQueuePosition(rhs.position)
        if lhsPosition != rhsPosition { return lhsPosition < rhsPosition }
        return lhs.episodeID < rhs.episodeID
    }

    public func addPodcastQueueEpisode(_ episodeID: ItemID, addedAt: Timestamp = Timestamp(Date())) throws {
        let state = try podcastQueueState()
        guard !state.episodeIDs.contains(episodeID) else { return }
        try replacePodcastQueue(try PodcastQueueState(
            episodeIDs: state.episodeIDs + [episodeID],
            currentEpisodeID: state.currentEpisodeID
        ), addedAt: addedAt)
    }

    public func removePodcastQueueEpisode(_ episodeID: ItemID) throws {
        let state = try podcastQueueState()
        let ids = state.episodeIDs.filter { $0 != episodeID }
        let current = state.currentEpisodeID == episodeID ? nil : state.currentEpisodeID
        try replacePodcastQueue(try PodcastQueueState(episodeIDs: ids, currentEpisodeID: current))
    }

    public func movePodcastQueueEpisode(from source: Int, to destination: Int) throws {
        let state = try podcastQueueState()
        guard state.episodeIDs.indices.contains(source), destination >= 0, destination < state.episodeIDs.count else {
            throw LocalLibraryStoreError.invalidPodcastState("queue move")
        }
        var ids = state.episodeIDs
        let value = ids.remove(at: source)
        ids.insert(value, at: destination)
        try replacePodcastQueue(try PodcastQueueState(episodeIDs: ids, currentEpisodeID: state.currentEpisodeID))
    }

    public func setCurrentPodcastQueueEpisode(_ episodeID: ItemID?) throws {
        let state = try podcastQueueState()
        try replacePodcastQueue(try PodcastQueueState(
            episodeIDs: state.episodeIDs,
            currentEpisodeID: episodeID
        ))
    }

    public func save(playbackSpeed: PodcastPlaybackSpeed) throws {
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastPlaybackSpeedRecord>())
        if let existing = records.first(where: { $0.itemID == playbackSpeed.itemID.rawValue }) {
            existing.speed = playbackSpeed.speed; existing.updatedAt = playbackSpeed.updatedAt.date
        } else { context.insert(LocalLibrarySchemaV6Models.PodcastPlaybackSpeedRecord(playbackSpeed)) }
        try context.save()
    }

    public func save(playbackRate speed: PodcastPlaybackSpeed) throws { try save(playbackSpeed: speed) }

    public func playbackSpeed(for itemID: ItemID) throws -> PodcastPlaybackSpeed? {
        let context = ModelContext(container)
        guard let record = try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastPlaybackSpeedRecord>()).first(where: { $0.itemID == itemID.rawValue }) else { return nil }
        return try PodcastPlaybackSpeed(itemID: itemID, speed: record.speed, updatedAt: Timestamp(record.updatedAt))
    }

}
