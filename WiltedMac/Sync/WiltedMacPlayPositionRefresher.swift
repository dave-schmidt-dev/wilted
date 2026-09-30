import Foundation
import OSLog
import WiltedLibrary

#if canImport(WiltedProducer)

private let refreshLog = Logger(subsystem: "com.zerodelta.wilted", category: "MacPlayRefresh")

/// Reads the phone's newest position when the Mac is about to start playing, so Play resumes where
/// the phone stopped without waiting for the next 30 s poll.
///
/// One fetch of the device records, bounded by `timeout` (`SyncCadence.playPressFetchTimeout`),
/// then the importer stores what is newer and this returns. Every way it can fail (no network, a
/// closed gate, the timeout) returns just the same: playback then starts from the position already
/// stored, exactly as before this existed. It never throws and never starts playback itself.
@MainActor
final class WiltedMacPlayPositionRefresher {
    typealias Fetch = @Sendable () async throws -> LibraryDeviceRecords

    private let fetch: Fetch
    private var inFlight: Task<LibraryDeviceRecords?, Never>?
    private let importer: WiltedMacPositionImporter
    private let timeout: Duration
    private let onRecords: (@MainActor (LibraryDeviceRecords) -> Void)?
    /// Presses that read fresh records.
    private(set) var refreshCount = 0
    /// Presses that went ahead without them.
    private(set) var skippedCount = 0

    init(
        fetch: @escaping Fetch,
        importer: WiltedMacPositionImporter,
        timeout: Duration = .seconds(SyncCadence.playPressFetchTimeout),
        onRecords: (@MainActor (LibraryDeviceRecords) -> Void)? = nil
    ) {
        self.fetch = fetch
        self.importer = importer
        self.timeout = timeout
        self.onRecords = onRecords
    }

    /// Fetches and imports; returns when the store holds the phone's newer position, or when the
    /// fetch failed or timed out.
    func refreshBeforePlay() async {
        guard let records = await fetchWithin() else {
            skippedCount += 1
            refreshLog.info("Play pressed without a fresh read of the phone's position; using the stored one")
            return
        }
        refreshCount += 1
        onRecords?(records)
        await importer.handleAwaiting(records)
    }

    /// The fetch's records, or nil when it fails or `timeout` passes first. A second press while a
    /// fetch is pending shares it instead of starting another, and a fetch that misses the timeout
    /// is cancelled, so repeated presses cannot pile up background reads.
    private func fetchWithin() async -> LibraryDeviceRecords? {
        let fetch = self.fetch
        let task = inFlight ?? Task { try? await fetch() }
        inFlight = task
        let records = await withCheckedContinuation { continuation in
            let race = Race(continuation)
            Task {
                let value = await task.value
                race.finish(value)
            }
            Task { [timeout] in
                try? await Task.sleep(for: timeout)
                race.finish(nil)
            }
        }
        if records == nil { task.cancel() }
        if inFlight == task { inFlight = nil }
        return records
    }

    /// Resumes the continuation once, with whichever finisher comes first.
    private final class Race: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<LibraryDeviceRecords?, Never>?

        init(_ continuation: CheckedContinuation<LibraryDeviceRecords?, Never>) { self.continuation = continuation }

        func finish(_ value: LibraryDeviceRecords?) {
            let taken = lock.withLock { () -> CheckedContinuation<LibraryDeviceRecords?, Never>? in
                defer { continuation = nil }
                return continuation
            }
            taken?.resume(returning: value)
        }
    }
}

#endif
