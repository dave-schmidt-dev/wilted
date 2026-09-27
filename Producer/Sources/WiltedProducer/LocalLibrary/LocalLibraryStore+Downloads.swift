import CryptoKit
import Foundation
import SwiftData
import WiltedDomain
import WiltedSync

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

    /// The media files under `directories` that no reachable record names and no
    /// in-flight writer holds. Read-only: the audit deletes nothing, and it is
    /// what every reclaim sweep starts from.
    public func unreferencedMediaFiles(in directories: [URL]) throws -> [URL] {
        let reachable = try reachableMediaPaths()
        let inFlight = inFlightMedia.inFlightPaths
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
                guard !reachable.contains(path), !inFlight.contains(path) else { continue }
                unreferenced.append(url)
            }
        }
        return unreferenced.sorted { $0.path < $1.path }
    }

    /// Deletes only what the audit reports. The audit runs first, in this
    /// method, so no deletion can precede it; the in-flight set is consulted
    /// again immediately before each removal so a writer that registered in
    /// between keeps its file.
    @discardableResult
    public func reclaimUnreferencedMedia(in directories: [URL]) throws -> Int {
        let unreferenced = try unreferencedMediaFiles(in: directories)
        var reclaimed = 0
        for url in unreferenced {
            guard !inFlightMedia.isInFlight(url) else { continue }
            do {
                try FileManager.default.removeItem(at: url)
                reclaimed += 1
            } catch {}
        }
        return reclaimed
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
