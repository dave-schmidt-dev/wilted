import CryptoKit
import Foundation
import WiltedDomain
import WiltedLibrary

private struct StoredPodcastChapterSource: Codable {
    let episodeID: ItemID
    let source: PodcastChapterSource
}

/// Podcast chapter metadata lives beside the library database rather than in
/// SwiftData, so adding it does not require a schema migration. Prepared marks
/// are keyed by episode and carry their exact audio revision in the payload.
extension LocalLibraryStore {
    public func savePodcastChapterSource(_ source: PodcastChapterSource?, for episodeID: ItemID) throws {
        let file = chapterSourceURL(for: episodeID)
        if let source {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let record = StoredPodcastChapterSource(episodeID: episodeID, source: source)
            try DurableFile.write(try Self.chapterEncoder().encode(record), to: file)
        } else if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }

    public func podcastChapterSource(for episodeID: ItemID) -> PodcastChapterSource? {
        let file = chapterSourceURL(for: episodeID)
        guard let data = try? Data(contentsOf: file), data.count <= 8 * 1_024,
              let record = try? JSONDecoder().decode(StoredPodcastChapterSource.self, from: data),
              record.episodeID == episodeID else { return nil }
        return record.source
    }

    public func savePreparedPodcastChapters(
        _ chapters: [PodcastChapterMark],
        for episodeID: ItemID,
        revisionID: RevisionID
    ) throws {
        guard let ready = try readyRevision(for: episodeID, revisionID: revisionID),
              FileManager.default.fileExists(atPath: ready.mediaURL.path) else {
            throw LocalLibraryStoreError.invalidPodcastState("chapter revision is not the current ready audio")
        }
        let set = try LibraryPodcastChapters(entryID: episodeID, revisionID: revisionID, chapters: chapters)
        let file = preparedChaptersURL(for: episodeID)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try DurableFile.write(set.encoded(), to: file)
    }

    public func preparedPodcastChapters(for episodeID: ItemID, revisionID: RevisionID) -> LibraryPodcastChapters? {
        let file = preparedChaptersURL(for: episodeID)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let count = attributes[.size] as? NSNumber, count.intValue <= LibraryPodcastChapters.maximumEncodedBytes,
              let data = try? Data(contentsOf: file),
              let chapters = try? JSONDecoder().decode(LibraryPodcastChapters.self, from: data),
              chapters.entryID == episodeID, chapters.revisionID == revisionID,
              (try? readyRevision(for: episodeID, revisionID: revisionID)) != nil else { return nil }
        return chapters
    }

    public func preparedPodcastChapters(
        for revisions: [ItemID: RevisionID]
    ) -> [ItemID: LibraryPodcastChapters] {
        revisions.reduce(into: [:]) { result, pair in
            if let chapters = preparedPodcastChapters(for: pair.key, revisionID: pair.value), !chapters.chapters.isEmpty {
                result[pair.key] = chapters
            }
        }
    }

    private func chapterSourceURL(for episodeID: ItemID) -> URL {
        chapterDirectoryURL.appendingPathComponent(Self.chapterFileKey(episodeID.rawValue) + ".source.json")
    }

    private func preparedChaptersURL(for episodeID: ItemID) -> URL {
        chapterDirectoryURL.appendingPathComponent(Self.chapterFileKey(episodeID.rawValue) + ".prepared.json")
    }

    private var chapterDirectoryURL: URL {
        url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".podcast-chapters", isDirectory: true)
    }

    private static func chapterFileKey(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func chapterEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
