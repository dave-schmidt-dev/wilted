import CryptoKit
import Foundation
import SwiftData
import WiltedDomain
import WiltedSync

/// What one media sweep did: files removed, bytes reclaimed, and records
/// cleared because the file they named was already gone.
public struct MediaSweepReport: Equatable, Sendable {
    public let files: Int
    public let bytes: Int64
    public let clearedRecords: Int

    public init(files: Int, bytes: Int64, clearedRecords: Int) {
        self.files = files
        self.bytes = bytes
        self.clearedRecords = clearedRecords
    }
}

extension LocalLibraryStore {
    public func save(download: PodcastDownload) throws {
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastDownloadRecord>())
        if let existing = records.first(where: { $0.episodeID == download.episodeID.rawValue }) {
            existing.status = download.status.rawValue; existing.bytesReceived = download.bytesReceived; existing.expectedByteCount = download.expectedByteCount
            existing.localURL = download.localURL?.absoluteString; existing.contentHash = download.contentHash; existing.updatedAt = download.updatedAt.date
            existing.failureKind = download.failureKind?.rawValue
        } else { context.insert(LocalLibrarySchemaV10Models.PodcastDownloadRecord(download)) }
        try context.save()
    }

    public func save(downloadState download: PodcastDownload) throws { try save(download: download) }

    /// Atomically commits immutable downloaded media metadata and its completed state.
    public func finalizePodcastDownload(revision: AudioRevision, mediaURL: URL, download: PodcastDownload) throws {
        guard revision.itemID == download.episodeID,
              download.status == .completed,
              download.localURL == mediaURL,
              download.contentHash == revision.contentHash,
              download.bytesReceived == revision.byteCount else {
            throw LocalLibraryStoreError.invalidPodcastState("completed download revision")
        }
        let context = ModelContext(container)
        let revisions = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.RevisionRecord>())
        if let existing = revisions.first(where: { $0.id == revision.revisionID.rawValue }) {
            guard existing.itemID == revision.itemID.rawValue,
                  existing.contentHash == revision.contentHash,
                  existing.mediaURL == mediaURL.absoluteString else {
                throw LocalLibraryStoreError.immutableRevision(revision.revisionID, site: .finalizedDownload)
            }
        } else {
            context.insert(LocalLibrarySchemaV3Models.RevisionRecord(revision, mediaURL: mediaURL))
        }
        let downloads = try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastDownloadRecord>())
        if let existing = downloads.first(where: { $0.episodeID == download.episodeID.rawValue }) {
            existing.status = download.status.rawValue
            existing.bytesReceived = download.bytesReceived
            existing.expectedByteCount = download.expectedByteCount
            existing.localURL = download.localURL?.absoluteString
            existing.contentHash = download.contentHash
            existing.updatedAt = download.updatedAt.date
            existing.failureKind = download.failureKind?.rawValue
        } else {
            context.insert(LocalLibrarySchemaV10Models.PodcastDownloadRecord(download))
        }
        try context.save()
    }

    /// Replaces one episode's audio revision with a prepared successor.
    ///
    /// Preparation rewrites the audio, so the superseded revision is not
    /// history: its bytes stop existing. Leaving its record behind would leave
    /// the store describing a file nothing can open, and `readyRevision` would
    /// hand it out the moment a newer record was missing. Revision records are
    /// immutable, so the old one is removed rather than edited, along with the
    /// transcript that described audio that is gone.
    ///
    /// Everything lands in one save. A partial commit here is the case that
    /// loses an episode: the caller deletes the original file once this
    /// returns, and it must never delete a file the store still points at.
    public func replaceReadyRevision(
        _ revision: AudioRevision,
        mediaURL: URL,
        transcript: Transcript,
        download: PodcastDownload,
        superseding superseded: RevisionID,
        outcome: PodcastPreparationOutcome,
        carrying playback: PlaybackState? = nil,
        lifetimeStatistics: [LifetimeStatisticContribution] = []
    ) throws {
        guard transcript.itemID == revision.itemID, transcript.revisionID == revision.revisionID else {
            throw LocalLibraryStoreError.revisionBelongsToDifferentItem
        }
        guard outcome.episodeID == revision.itemID, outcome.revisionID == revision.revisionID else {
            throw LocalLibraryStoreError.revisionBelongsToDifferentItem
        }
        guard revision.itemID == download.episodeID, download.status == .completed,
              download.localURL == mediaURL, download.contentHash == revision.contentHash,
              download.bytesReceived == revision.byteCount else {
            throw LocalLibraryStoreError.invalidPodcastState("prepared download revision")
        }
        guard playback == nil || (playback?.itemID == revision.itemID && playback?.revisionID == revision.revisionID) else {
            throw LocalLibraryStoreError.revisionBelongsToDifferentItem
        }
        guard superseded != revision.revisionID else {
            throw LocalLibraryStoreError.immutableRevision(revision.revisionID, site: .replacementSupersedesItself)
        }
        let context = ModelContext(container)
        let revisions = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.RevisionRecord>())
        if let existing = revisions.first(where: { $0.id == revision.revisionID.rawValue }) {
            guard existing.itemID == revision.itemID.rawValue,
                  existing.contentHash == revision.contentHash,
                  existing.mediaURL == mediaURL.absoluteString else {
                throw LocalLibraryStoreError.immutableRevision(revision.revisionID, site: .replacement)
            }
        } else {
            context.insert(LocalLibrarySchemaV3Models.RevisionRecord(revision, mediaURL: mediaURL))
        }
        try upsert(transcript, in: context)

        for record in revisions where record.id == superseded.rawValue && record.itemID == revision.itemID.rawValue {
            context.delete(record)
        }
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV7Models.TranscriptRecord>())
        where record.itemID == revision.itemID.rawValue && record.revisionID == superseded.rawValue {
            context.delete(record)
        }
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.PlaybackRecord>())
        where record.itemID == revision.itemID.rawValue && record.revisionID == superseded.rawValue {
            context.delete(record)
        }
        if let playback {
            context.insert(LocalLibrarySchemaV3Models.PlaybackRecord(playback))
        }

        let downloads = try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastDownloadRecord>())
        if let existing = downloads.first(where: { $0.episodeID == download.episodeID.rawValue }) {
            existing.status = download.status.rawValue
            existing.bytesReceived = download.bytesReceived
            existing.expectedByteCount = download.expectedByteCount
            existing.localURL = download.localURL?.absoluteString
            existing.contentHash = download.contentHash
            existing.updatedAt = download.updatedAt.date
            existing.failureKind = download.failureKind?.rawValue
        } else {
            context.insert(LocalLibrarySchemaV10Models.PodcastDownloadRecord(download))
        }
        try upsertPreparationOutcome(outcome, in: context)
        try appendLifetimeStatistics(lifetimeStatistics, in: context)
        try context.save()
    }

    /// The paths any reachable record still names: revisions, downloads, and
    /// artwork. A file not in this set and not in flight is an orphan.
    private func reachableMediaPaths() throws -> Set<String> {
        let context = ModelContext(container)
        var paths: Set<String> = []
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.RevisionRecord>()) {
            if let value = record.mediaURL, let url = URL(string: value) {
                paths.insert(url.standardizedFileURL.path)
            }
        }
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastDownloadRecord>()) {
            if let value = record.localURL, let url = URL(string: value) {
                paths.insert(url.standardizedFileURL.path)
            }
        }
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastArtworkRecord>()) {
            if let value = record.localURL, let url = URL(string: value) {
                paths.insert(url.standardizedFileURL.path)
            }
        }
        return paths
    }

    /// The media files under `directories` that no reachable record names, no
    /// in-flight writer holds, and the caller did not exclude. Read-only: the
    /// audit deletes nothing, and it is what every sweep starts from.
    public func unreferencedMediaFiles(in directories: [URL], excluding: Set<URL> = []) throws -> [URL] {
        let reachable = try reachableMediaPaths()
        let inFlight = inFlightMedia.inFlightPaths
        let excluded = Set(excluding.map { $0.standardizedFileURL.path })
        let manager = FileManager.default
        var unreferenced: [URL] = []
        for directory in directories {
            guard let walker = manager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [],
                errorHandler: { _, _ in true }
            ) else { continue }
            for case let url as URL in walker {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                    continue
                }
                let path = url.standardizedFileURL.path
                guard !reachable.contains(path), !inFlight.contains(path), !excluded.contains(path) else { continue }
                unreferenced.append(url)
            }
        }
        return unreferenced.sorted { $0.path < $1.path }
    }

    /// Deletes each listed file the current store no longer names.
    ///
    /// This is the single deletion primitive for removal paths: dismissal,
    /// unsubscribe, and the sweep all funnel through it, so they agree on what
    /// "unreferenced" means. A path outside the library directory is never
    /// removed, a surviving record naming the path keeps it, and the in-flight
    /// registry is consulted immediately before each removal. A file that is
    /// missing or cannot be removed is skipped rather than failing the caller.
    @discardableResult
    public func deleteMediaIfUnreferenced(_ urls: [URL]) -> MediaSweepReport {
        guard let reachable = try? reachableMediaPaths() else {
            return MediaSweepReport(files: 0, bytes: 0, clearedRecords: 0)
        }
        let manager = FileManager.default
        var files = 0
        var bytes: Int64 = 0
        for url in urls {
            let path = url.standardizedFileURL.path
            guard isInsideLibraryDirectory(url), !reachable.contains(path), !inFlightMedia.isInFlight(url) else {
                continue
            }
            guard let size = Self.regularFileSize(at: url) else { continue }
            do {
                try manager.removeItem(at: url)
                files += 1
                bytes += size
            } catch {}
        }
        return MediaSweepReport(files: files, bytes: bytes, clearedRecords: 0)
    }

    /// Deletes the unreferenced media under `directories` and reconciles the
    /// records whose files are already gone.
    ///
    /// Deletion is direct: episode audio is a public download that can be
    /// fetched again, so the sweep keeps no quarantine, manifest, or restore.
    /// The audit runs first, in this method, and the in-flight registry is
    /// consulted again immediately before each removal so a writer that
    /// registered in between keeps its file. Only the directories the caller
    /// names are walked, and only files inside the library directory are
    /// removed.
    ///
    /// The other direction is reconciled too: a completed download record or a
    /// revision record whose file is missing is cleared, because a record
    /// naming audio that does not exist is the same lie as an unowned file. A
    /// missing library media directory disables clearing entirely, so an
    /// unmounted volume is not mistaken for an emptied library.
    public func sweepUnreferencedMedia(
        in directories: [URL],
        excluding: Set<URL> = []
    ) async throws -> MediaSweepReport {
        let unreferenced = try unreferencedMediaFiles(in: directories, excluding: excluding)
        let manager = FileManager.default
        var files = 0
        var bytes: Int64 = 0
        for url in unreferenced {
            guard isInsideLibraryDirectory(url), !inFlightMedia.isInFlight(url) else { continue }
            guard let size = Self.regularFileSize(at: url) else { continue }
            do {
                try manager.removeItem(at: url)
                files += 1
                bytes += size
            } catch {}
        }
        return MediaSweepReport(
            files: files, bytes: bytes, clearedRecords: try clearRecordsForMissingMedia()
        )
    }

    /// Whether `url` resolves inside this store's library directory.
    ///
    /// The deletion primitives only remove media the library owns; a record
    /// naming a file outside it is not something a sweep may touch.
    private func isInsideLibraryDirectory(_ url: URL) -> Bool {
        let libraryPath = self.url.deletingLastPathComponent().standardizedFileURL.path
        return url.standardizedFileURL.path.hasPrefix(libraryPath + "/")
    }

    /// The size of `url` when it is a regular file, or nil when it is missing,
    /// a directory, or otherwise not removable media.
    private static func regularFileSize(at url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true else { return nil }
        return Int64(values.fileSize ?? 0)
    }

    /// Clears the records whose named media file is gone.
    ///
    /// A completed download loses its record entirely, which is how
    /// `download(for:)` reports "never downloaded"; a revision record is
    /// deleted the way the superseding paths delete one; a revision that names no
    /// media is not an audio record and is left alone. A path an
    /// in-flight registration holds is left alone, and nothing is cleared
    /// while the library media directory itself is missing.
    private func clearRecordsForMissingMedia() throws -> Int {
        let manager = FileManager.default
        let mediaDirectory = self.url.deletingLastPathComponent().appendingPathComponent("media", isDirectory: true)
        guard manager.fileExists(atPath: mediaDirectory.path) else { return 0 }
        let context = ModelContext(container)
        var cleared = 0
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastDownloadRecord>())
        where record.status == PodcastDownloadStatus.completed.rawValue {
            if let mediaURL = record.localURL.flatMap(URL.init),
               manager.fileExists(atPath: mediaURL.path) || inFlightMedia.isInFlight(mediaURL) {
                continue
            }
            context.delete(record)
            cleared += 1
        }
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.RevisionRecord>()) {
            guard let mediaURL = record.mediaURL.flatMap(URL.init) else { continue }
            if manager.fileExists(atPath: mediaURL.path) || inFlightMedia.isInFlight(mediaURL) { continue }
            context.delete(record)
            cleared += 1
        }
        if cleared > 0 { try context.save() }
        return cleared
    }

    public func download(for episodeID: ItemID) throws -> PodcastDownload? {
        let context = ModelContext(container)
        guard let record = try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastDownloadRecord>()).first(where: { $0.episodeID == episodeID.rawValue }),
              let episodeID = try? ItemID(rawValue: record.episodeID), let status = PodcastDownloadStatus(rawValue: record.status) else { return nil }
        return try PodcastDownload(episodeID: episodeID, status: status, bytesReceived: record.bytesReceived,
                                   expectedByteCount: record.expectedByteCount, localURL: record.localURL.flatMap(URL.init),
                                   contentHash: record.contentHash, updatedAt: Timestamp(record.updatedAt),
                                   failureKind: record.failureKind.flatMap(PodcastDownloadFailureKind.init(rawValue:)))
    }

    public func downloads() throws -> [PodcastDownload] {
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastDownloadRecord>()).compactMap { record in
            guard let episodeID = try? ItemID(rawValue: record.episodeID), let status = PodcastDownloadStatus(rawValue: record.status) else { return nil }
            return try? PodcastDownload(episodeID: episodeID, status: status, bytesReceived: record.bytesReceived,
                                        expectedByteCount: record.expectedByteCount, localURL: record.localURL.flatMap(URL.init),
                                        contentHash: record.contentHash, updatedAt: Timestamp(record.updatedAt),
                                        failureKind: record.failureKind.flatMap(PodcastDownloadFailureKind.init(rawValue:)))
        }
    }

    // MARK: Preparation outcome, listening completion, and retirement (V10)

}
