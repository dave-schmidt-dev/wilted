import Foundation
import WiltedDomain
import WiltedLibrary

/// What the phone holds on disk for downloaded episode audio.
struct LibraryCacheSummary: Equatable, Sendable {
    var episodeCount = 0
    var byteCount: Int64 = 0
}

/// The Settings page's view of the library model: cache size, bulk removal and the sync summary.
extension LibraryAppModel {
    /// Size of the audio cache; `excluding` leaves out an entry the caller will not remove.
    func cacheSummary(excluding kept: ItemID? = nil) async -> LibraryCacheSummary {
        let stored = await mediaCache.storedAudioByteCounts().filter { $0.key != kept }
        return LibraryCacheSummary(episodeCount: stored.count, byteCount: stored.values.reduce(0, +))
    }

    /// Deletes every cached episode except `kept` (the one playing) and any with a request running.
    /// The Mac's copies are untouched. Returns how many were removed.
    @discardableResult
    func removeAllDownloadedAudio(keeping kept: ItemID?) async -> Int {
        var removed = 0
        for entryID in await mediaCache.storedAudioByteCounts().keys where entryID != kept && mediaRuns[entryID] == nil {
            await removeFromPhone(entryID: entryID)
            if case .failed = media[entryID] { continue }
            removed += 1
        }
        return removed
    }

    var publicationVerified: Bool { !accountQuarantined && lastSynchronizedAt != nil }
    var publicationSummary: String { WiltedPublicationAge.summary(lastObservedPublication?.publishedAt, verified: publicationVerified, now: now()) }
    var publicationDetail: String { WiltedPublicationAge.detail(lastObservedPublication?.publishedAt) }
    var publicationQualifier: String? {
        WiltedPublicationAge.qualifier(verified: publicationVerified, pending: hasPendingRefresh,
            failed: errorMessage != nil, held: accountQuarantined)
    }
    var syncSummary: LibrarySettingsFormat.SyncSummary {
        LibrarySettingsFormat.sync(
            isRefreshing: isRefreshing, quarantined: accountQuarantined, error: errorMessage,
            lastRefresh: lastSynchronizedAt, throttleNotice: throttleNotice,
            throttleRetrying: throttleRetrying)
    }

    /// The one sync status the Larder shows, or nil when there is nothing to say.
    var syncBanner: LibrarySyncBanner? {
        LibrarySyncBanner.resolve(
            quarantined: accountQuarantined, throttleNotice: throttleNotice, retrying: throttleRetrying, error: errorMessage) ?? .publication
    }
}
