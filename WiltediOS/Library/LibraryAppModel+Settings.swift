import Foundation
import WiltedDomain
import WiltedLibrary

/// What the phone holds on disk for downloaded episode audio.
struct LibraryCacheSummary: Equatable, Sendable {
    var episodeCount = 0
    var byteCount: Int64 = 0
}

/// The Settings page's view of the library model: cache size, bulk removal, the Mac's lifetime
/// statistics and when the Mac was last heard from. Read-only toward the library; the phone
/// never writes statistics.
extension LibraryAppModel {
    /// Size of the audio cache; `excluding` leaves out an entry the caller will not remove.
    func cacheSummary(excluding kept: ItemID? = nil) async -> LibraryCacheSummary {
        let cached = await mediaCache.cachedEntries().filter { $0.key != kept }
        return LibraryCacheSummary(episodeCount: cached.count, byteCount: cached.values.reduce(0) { $0 + $1.byteCount })
    }

    /// Deletes every cached episode except `kept` (the one playing) and any with a request running.
    /// The Mac's copies are untouched. Returns how many were removed.
    @discardableResult
    func removeAllDownloadedAudio(keeping kept: ItemID?) async -> Int {
        var removed = 0
        for entryID in await mediaCache.cachedEntries().keys where entryID != kept && mediaRuns[entryID] == nil {
            await removeFromPhone(entryID: entryID)
            if case .failed = media[entryID] { continue }
            removed += 1
        }
        return removed
    }

    /// Reads the Mac's published statistics with the library refresh. A failed read, or nothing
    /// published yet, keeps the last known value (nil until the Mac first publishes).
    func refreshStats() async {
        if let stats = try? await transport.readStats() { lifetimeStats = stats }
    }

    /// The newest record any Mac wrote, by the server's own clock. Nil until one exists. Macs
    /// name themselves `mac...`; every phone is `iphone-...`.
    static func macLastSeen(from records: LibraryDeviceRecords, excluding deviceID: String) -> Date? {
        (records.nowPlaying + records.progress)
            .filter { $0.record.deviceID != deviceID && $0.record.deviceID.hasPrefix("mac") }
            .map(\.serverModifiedAt).max()
    }

    var syncSummary: LibrarySettingsFormat.SyncSummary {
        LibrarySettingsFormat.sync(
            isRefreshing: isRefreshing, quarantined: accountQuarantined, error: errorMessage,
            lastRefresh: lastSynchronizedAt)
    }
}
