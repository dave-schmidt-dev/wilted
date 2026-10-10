import Foundation
import SwiftData
import WiltedDomain

/// One audiobook volume ready to be committed: its immutable revision, its media file
/// (already in the media folder) and the display fields of its `AudiobookRecord`.
struct AudiobookVolumeSave: Sendable {
    let itemID: ItemID
    let revision: AudioRevision
    let mediaURL: URL
    let title: String
    let author: String?
    let chapters: [AudiobookChapterMark]
    let sourceFormat: String
    let volumeIndex: Int
    let volumeCount: Int
    let createdAt: Date
}

/// A saved audiobook volume as the library reads it back.
public struct StoredAudiobook: Sendable, Equatable {
    public let itemID: ItemID
    public let title: String
    public let author: String?
    public let durationSeconds: Double
    public let chapters: [AudiobookChapterMark]
    public let sourceFormat: String
    public let volumeIndex: Int
    public let volumeCount: Int
    public let isRemoved: Bool
}

extension LocalLibraryStore {
    /// Where this store's media files live. Importers write here so the orphan sweep covers them.
    public nonisolated var mediaDirectory: URL {
        url.deletingLastPathComponent().appendingPathComponent("media", isDirectory: true)
    }

    /// Commits every volume of one import in a single save: each ready revision, its
    /// `AudiobookRecord`, and its place at the end of the Larder queue, in volume order.
    /// A volume whose record already exists is left alone. No book is visible without a
    /// ready revision, and a throw before the save leaves nothing behind.
    func saveAudiobookVolumes(_ volumes: [AudiobookVolumeSave]) throws {
        let context = ModelContext(container)
        let revisions = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.RevisionRecord>())
        let books = Set(try context.fetch(FetchDescriptor<LocalLibrarySchemaV17Models.AudiobookRecord>()).map(\.id))
        let queue = try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastQueueRecord>())
        // The current item is stored at an offset, so the end of the queue is the largest decoded position.
        var next = (queue.map { $0.position >= Self.podcastCurrentPositionOffset
            ? $0.position - Self.podcastCurrentPositionOffset : $0.position }.max() ?? -1) + 1
        for volume in volumes where !books.contains(volume.itemID.rawValue) {
            let revision = volume.revision
            if let existing = revisions.first(where: { $0.id == revision.revisionID.rawValue }) {
                guard existing.itemID == revision.itemID.rawValue, existing.contentHash == revision.contentHash,
                      existing.mediaURL == volume.mediaURL.absoluteString else {
                    throw LocalLibraryStoreError.immutableRevision(revision.revisionID, site: .readyRevision)
                }
            } else {
                context.insert(LocalLibrarySchemaV3Models.RevisionRecord(revision, mediaURL: volume.mediaURL))
            }
            context.insert(LocalLibrarySchemaV17Models.AudiobookRecord(
                id: volume.itemID.rawValue, title: volume.title, author: volume.author,
                durationSeconds: revision.durationSeconds, chapters: try Self.encodeChapters(volume.chapters),
                sourceFormat: volume.sourceFormat, volumeIndex: volume.volumeIndex,
                volumeCount: volume.volumeCount, createdAt: volume.createdAt
            ))
            context.insert(LocalLibrarySchemaV6Models.PodcastQueueRecord(
                try PodcastQueueEntry(episodeID: volume.itemID, position: next, addedAt: Timestamp(volume.createdAt))
            ))
            next += 1
        }
        try context.save()
    }

    public func audiobook(_ itemID: ItemID) throws -> StoredAudiobook? {
        let id = itemID.rawValue
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<LocalLibrarySchemaV17Models.AudiobookRecord>(
            predicate: #Predicate { $0.id == id }
        )).first.flatMap(Self.storedAudiobook)
    }

    /// Every saved audiobook volume, books in import order and volumes in order within a book.
    public func audiobooks() throws -> [StoredAudiobook] {
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<LocalLibrarySchemaV17Models.AudiobookRecord>(
            sortBy: [SortDescriptor(\.createdAt), SortDescriptor(\.volumeIndex)]
        )).compactMap(Self.storedAudiobook)
    }

    /// Whether every volume of this digest and layout is already saved. Reads volume 0's
    /// volume count, then checks each volume ID, so no media is touched.
    public func hasCompleteAudiobook(contentDigest: String, layout: String) throws -> Bool {
        guard let first = try audiobook(ItemID.audiobook(contentDigest: contentDigest, layout: layout, volume: 0)) else {
            return false
        }
        for volume in 1..<max(first.volumeCount, 1) {
            guard try audiobook(ItemID.audiobook(contentDigest: contentDigest, layout: layout, volume: volume)) != nil else {
                return false
            }
        }
        return true
    }

    private static func encodeChapters(_ chapters: [AudiobookChapterMark]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(chapters)
    }

    private static func storedAudiobook(_ record: LocalLibrarySchemaV17Models.AudiobookRecord) -> StoredAudiobook? {
        guard let itemID = try? ItemID(rawValue: record.id) else { return nil }
        return StoredAudiobook(
            itemID: itemID, title: record.title, author: record.author, durationSeconds: record.durationSeconds,
            chapters: (try? JSONDecoder().decode([AudiobookChapterMark].self, from: record.chapters)) ?? [],
            sourceFormat: record.sourceFormat, volumeIndex: record.volumeIndex,
            volumeCount: record.volumeCount, isRemoved: record.isRemoved
        )
    }
}
