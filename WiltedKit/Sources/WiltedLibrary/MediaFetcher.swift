import Foundation

/// How one fetch ended. `cached` carries the final location inside the cache.
public enum MediaFetchOutcome: Sendable, Equatable {
    case cached(URL)
    case notReady
    case failed(MediaFailureReason)
}

/// Runs one on-demand media transfer: asks the transport for the file, watches for stalls,
/// verifies byte count and content hash, and only then moves the file into the cache.
/// A delivered file that fails verification is deleted, so a bad file is never cached.
public struct MediaFetcher: Sendable {
    /// Longest a transfer may go without receiving more bytes before it fails.
    public static let defaultWatchdog: Duration = .seconds(300)

    public typealias StateHandler = @Sendable (MediaTransferState) -> Void

    private let cache: any MediaCacheStore
    private let watchdog: Duration

    /// Verifies one local target off the caller's actor; cache listings never hash the whole cache.
    public static func verifies(_ url: URL, byteCount: Int64, contentHash: String) async -> Bool {
        await Task.detached(priority: .utility) {
            guard url.isFileURL, MediaHash.isWellFormed(contentHash),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  Int64(values.fileSize ?? -1) == byteCount,
                  FileManager.default.isReadableFile(atPath: url.path),
                  let hash = try? MediaHash.sha256(fileAt: url), hash == contentHash else { return false }
            return true
        }.value
    }

    public init(cache: any MediaCacheStore, watchdog: Duration = MediaFetcher.defaultWatchdog) {
        self.cache = cache
        self.watchdog = watchdog
    }

    /// Fetches `offer` through `transport` and reports each state change to `onState`.
    /// Only cancellation throws; every other end is an outcome.
    public func fetch(
        _ offer: LibraryMediaOffer,
        from transport: any LibraryTransport,
        admission: MediaCacheAdmission,
        onState: @escaping StateHandler = { _ in }
    ) async throws -> MediaFetchOutcome {
        guard offer.state == .ready, offer.isPrepared else {
            onState(.notReady)
            return .notReady
        }
        guard await liveAdmission(admission, offer: offer, transport: transport) else {
            return fail(.cacheFailed("Media admission changed"), onState)
        }
        if let existing = await cache.cachedFile(for: offer, admission: admission),
           await liveAdmission(admission, offer: offer, transport: transport),
           await Self.verifies(existing, byteCount: offer.byteCount, contentHash: offer.contentHash),
           await liveAdmission(admission, offer: offer, transport: transport) {
            onState(.cached)
            return .cached(existing)
        }
        guard await liveAdmission(admission, offer: offer, transport: transport) else {
            return fail(.cacheFailed("Media admission changed"), onState)
        }
        onState(.awaiting)
        let tracker = ProgressTracker()
        let total = offer.byteCount
        let delivered: URL
        do {
            delivered = try await withThrowingTaskGroup(of: URL?.self) { group in
                group.addTask {
                    try await transport.fetchMedia(offer) { bytes in
                        guard tracker.record(bytes) else { return }
                        onState(.downloading(bytes: bytes, total: total))
                    }
                }
                group.addTask {
                    try await Self.stall(tracker, after: watchdog)
                    return nil
                }
                defer { group.cancelAll() }
                for try await result in group {
                    if let result { return result }
                }
                throw CancellationError()
            }
        } catch is StalledError {
            onState(.failed(.timedOut))
            return .failed(.timedOut)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let reason = MediaFailureReason.deliveryFailed(String(describing: error))
            onState(.failed(reason))
            return .failed(reason)
        }
        guard await liveAdmission(admission, offer: offer, transport: transport) else {
            discard(delivered)
            return fail(.cacheFailed("Media admission changed"), onState)
        }
        let outcome = try await acceptDelivery(deliveredFile: delivered, for: offer, admission: admission,
            validation: { await liveAdmission(admission, offer: offer, transport: transport) }) { state in
            if state != .cached { onState(state) }
        }
        guard await liveAdmission(admission, offer: offer, transport: transport) else {
            return fail(.cacheFailed("Media admission changed"), onState)
        }
        if case .cached = outcome { onState(.cached) }
        return outcome
    }

    /// Verifies a delivered file and moves it into the cache. Re-delivering an offer that is
    /// already cached discards the duplicate and reports the existing file.
    public func accept(
        deliveredFile: URL,
        for offer: LibraryMediaOffer,
        admission: MediaCacheAdmission,
        onState: @escaping StateHandler = { _ in }
    ) async throws -> MediaFetchOutcome {
        try await acceptDelivery(deliveredFile: deliveredFile, for: offer, admission: admission,
            validation: { await cache.permits(admission, for: offer) }, onState: onState)
    }

    private func acceptDelivery(deliveredFile: URL, for offer: LibraryMediaOffer, admission: MediaCacheAdmission,
                                validation: @escaping @Sendable () async -> Bool,
                                onState: @escaping StateHandler) async throws -> MediaFetchOutcome {
        guard offer.state == .ready, offer.isPrepared else { onState(.notReady); return .notReady }
        guard await validation() else { return fail(.cacheFailed("Media admission changed"), onState) }
        if let existing = await cache.cachedFile(for: offer, admission: admission),
           await validation(),
           await Self.verifies(existing, byteCount: offer.byteCount, contentHash: offer.contentHash),
           await validation() {
            if existing != deliveredFile { discard(deliveredFile) }
            onState(.cached)
            return .cached(existing)
        }
        guard await validation() else { return fail(.cacheFailed("Media admission changed"), onState) }
        onState(.verifying)
        let actual: Int64
        do {
            let size = try FileManager.default.attributesOfItem(atPath: deliveredFile.path)[.size] as? NSNumber
            actual = size?.int64Value ?? -1
        } catch {
            return fail(.deliveryFailed("delivered file unreadable: \(error.localizedDescription)"), onState)
        }
        guard actual == offer.byteCount else {
            discard(deliveredFile)
            return fail(.byteCountMismatch(expected: offer.byteCount, actual: actual), onState)
        }
        let hash: String
        do {
            hash = try await Task.detached(priority: .utility) { try MediaHash.sha256(fileAt: deliveredFile) }.value
        } catch {
            return fail(.deliveryFailed("hashing failed: \(error.localizedDescription)"), onState)
        }
        guard await validation() else {
            discard(deliveredFile)
            return fail(.cacheFailed("Media admission changed"), onState)
        }
        guard hash == offer.contentHash else {
            discard(deliveredFile)
            return fail(.hashMismatch, onState)
        }
        do {
            let stored = try await cache.adopt(verifiedFile: deliveredFile, for: offer, admission: admission)
            guard await validation() else {
                return fail(.cacheFailed("Media admission changed"), onState)
            }
            onState(.cached)
            return .cached(stored)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return fail(.cacheFailed(String(describing: error)), onState)
        }
    }

    private func liveAdmission(_ admission: MediaCacheAdmission, offer: LibraryMediaOffer,
                               transport: any LibraryTransport) async -> Bool {
        guard await transport.verifiedOwnerToken() == admission.ownerToken,
              await transport.operationGeneration() == admission.transportGeneration,
              await cache.permits(admission, for: offer),
              await transport.verifiedOwnerToken() == admission.ownerToken,
              await transport.operationGeneration() == admission.transportGeneration else { return false }
        return true
    }

    private func fail(_ reason: MediaFailureReason, _ onState: StateHandler) -> MediaFetchOutcome {
        onState(.failed(reason))
        return .failed(reason)
    }

    private func discard(_ url: URL) { try? FileManager.default.removeItem(at: url) }

    private struct StalledError: Error {}

    /// Returns only by throwing `StalledError` once no byte has arrived for `interval`,
    /// or `CancellationError` when the transfer finished first.
    private static func stall(_ tracker: ProgressTracker, after interval: Duration) async throws {
        let clock = ContinuousClock()
        while true {
            let deadline = tracker.lastProgress + interval
            if clock.now >= deadline { throw StalledError() }
            try await clock.sleep(until: deadline)
        }
    }
}

/// Thread-safe record of the last time the received byte count grew.
private final class ProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Int64 = 0
    private var last = ContinuousClock.now

    var lastProgress: ContinuousClock.Instant {
        lock.lock()
        defer { lock.unlock() }
        return last
    }

    /// True when `received` is new progress.
    func record(_ received: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard received > bytes else { return false }
        bytes = received
        last = ContinuousClock.now
        return true
    }
}
