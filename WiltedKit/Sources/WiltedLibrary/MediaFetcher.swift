import Foundation
import OSLog

private let fetchLog = Logger(subsystem: "com.zerodelta.wilted", category: "MediaFetch")

/// How one fetch ended. `cached` carries the final location inside the cache.
public enum MediaFetchOutcome: Sendable, Equatable {
    case cached(URL)
    case notReady
    case failed(MediaFailureReason)
}

/// Why the transport delivered nothing, by cause, so a surface can say it in plain words.
///
/// `MediaFetcher` reports a failed delivery as `MediaFailureReason.deliveryFailed(cause.rawValue)`;
/// the transport's own error text goes to the log and never into the reason.
public enum MediaFetchFailure: String, Sendable, CaseIterable {
    /// The phone could not reach iCloud, and the automatic retries did not help.
    case offline
    /// The Mac's copy is not on the server to fetch.
    case macNotAnswering
    /// What arrived is not the file the Mac offered.
    case mismatch
    /// The audio is over the transport's size limit.
    case tooLarge
    case other
}

public extension MediaFailureReason {
    /// The typed cause of a `deliveryFailed` reason (`.other` for free text), or nil for every other reason.
    var fetchFailure: MediaFetchFailure? {
        guard case let .deliveryFailed(detail) = self else { return nil }
        return MediaFetchFailure(rawValue: detail) ?? .other
    }
}

/// An automatic retry about to happen: attempt `attempt` of `attempts` starts after `delay`.
public struct MediaFetchRetry: Sendable, Equatable {
    public let attempt: Int
    public let attempts: Int
    public let delay: Duration
    /// What ended the previous attempt.
    public let cause: MediaFetchFailure

    public init(attempt: Int, attempts: Int, delay: Duration, cause: MediaFetchFailure) {
        self.attempt = attempt
        self.attempts = attempts
        self.delay = delay
        self.cause = cause
    }
}

/// Sorts transport errors into "may pass if tried again shortly" and "will not change", and names
/// their cause, without importing CloudKit.
///
/// CloudKit errors arrive in the two shapes `TransportPressureClassifier` reads: a `CKErrorDomain`
/// error, or the CloudKit adapter's `cloudKit(code: N, message: …)` by its printed form. The adapter
/// keeps only the code, so a URL loading error wrapped there arrives by its negative `URLError` code.
public enum MediaFetchErrorClassifier {
    /// `CKError.Code.networkUnavailable` and `.networkFailure`.
    static let networkCodes: Set<Int> = [3, 4]
    /// `CKError.Code.serviceUnavailable`, `.requestRateLimited` and `.zoneBusy`.
    static let busyCodes: Set<Int> = [
        TransportPressureClassifier.serviceUnavailableCode, TransportPressureClassifier.requestRateLimitedCode,
        TransportPressureClassifier.zoneBusyCode,
    ]
    /// `CKError.Code.unknownItem`: the record is not on the server.
    static let unknownItemCode = 11
    /// Failures of the connection itself. `URLError.unknown` (-1) is left out on purpose: the CloudKit
    /// adapter reports its own "raw operations are unavailable" as code -1.
    static let connectionCodes: Set<Int> = Set([
        URLError.Code.timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed,
        .notConnectedToInternet, .internationalRoamingOff, .callIsActive, .dataNotAllowed,
    ].map(\.rawValue))

    /// True for network, availability, rate-limit and busy errors, and for a closed `TransportGate`.
    /// A missing record, a size limit or any other transport refusal is not transient.
    public static func isTransient(_ error: Error) -> Bool {
        if error is TransportThrottled { return true }
        if let url = error as? URLError { return connectionCodes.contains(url.code.rawValue) }
        guard let code = code(of: error) else { return false }
        return networkCodes.contains(code) || busyCodes.contains(code) || connectionCodes.contains(code)
    }

    /// The cause a person is told about.
    public static func failure(for error: Error) -> MediaFetchFailure {
        // The CloudKit adapter states its size limit only in words ("exceeds the size limit").
        if case let LibraryTransportError.transport(text) = error, text.contains("size limit") { return .tooLarge }
        if let url = error as? URLError { return connectionCodes.contains(url.code.rawValue) ? .offline : .other }
        guard let code = code(of: error) else { return .other }
        if networkCodes.contains(code) || connectionCodes.contains(code) { return .offline }
        if code == unknownItemCode { return .macNotAnswering }
        return .other
    }

    /// The error's name and value for the log, e.g. `CloudKitSyncError.cloudKit(code: 4, message: "…")`.
    public static func logDescription(_ error: Error) -> String {
        "\(type(of: error)).\(String(describing: error))"
    }

    private static func code(of error: Error) -> Int? {
        let nsError = error as NSError
        if nsError.domain == "CKErrorDomain" { return nsError.code }
        let text = String(describing: error)
        guard let regex = try? NSRegularExpression(pattern: #"cloudKit\(code: (-?\d+)"#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[range])
    }
}

/// The clock a fetch measures stalls on, as offsets from when the fetcher was made.
struct MediaFetchTimer: Sendable {
    let now: @Sendable () -> Duration
    let sleep: @Sendable (_ until: Duration) async throws -> Void

    init<C: Clock>(_ clock: C) where C.Duration == Duration {
        let origin = clock.now
        now = { origin.duration(to: clock.now) }
        sleep = { deadline in try await clock.sleep(until: origin.advanced(by: deadline), tolerance: nil) }
    }
}

/// Runs one on-demand media transfer: asks the transport for the file, watches for stalls,
/// verifies byte count and content hash, and only then moves the file into the cache.
/// A delivered file that fails verification is deleted, so a bad file is never cached.
///
/// A transient transport failure (see `MediaFetchErrorClassifier.isTransient`) is retried
/// automatically after each of `retryDelays`, so three attempts in all by default. Each retry
/// downloads the whole file again; nothing resumes from a byte offset.
public struct MediaFetcher: Sendable {
    /// Longest a transfer may go without receiving more bytes before it fails.
    public static let defaultWatchdog: Duration = .seconds(300)
    /// The waits before the second and third attempts.
    public static let defaultRetryDelays: [Duration] = [.seconds(2), .seconds(8)]
    /// Longest a retry waits for a closed `TransportGate` to reopen.
    static let maximumThrottleWait: TimeInterval = 60

    public typealias StateHandler = @Sendable (MediaTransferState) -> Void
    public typealias RetryHandler = @Sendable (MediaFetchRetry) -> Void
    public typealias Sleeper = @Sendable (Duration) async throws -> Void

    private let cache: any MediaCacheStore
    private let watchdog: Duration
    private let retryDelays: [Duration]
    private let timer: MediaFetchTimer
    private let sleep: Sleeper

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

    /// - Parameters:
    ///   - retryDelays: the wait before each automatic retry; empty means a single attempt.
    ///   - sleep: how a retry waits. Tests replace it so a retry costs no real time.
    public init(
        cache: any MediaCacheStore, watchdog: Duration = MediaFetcher.defaultWatchdog,
        retryDelays: [Duration] = MediaFetcher.defaultRetryDelays,
        sleep: @escaping Sleeper = { try await Task.sleep(for: $0) }
    ) {
        self.init(cache: cache, watchdog: watchdog, retryDelays: retryDelays, clock: ContinuousClock(), sleep: sleep)
    }

    /// As above, measuring stalls on `clock`, so a test can move time by hand.
    public init<C: Clock>(
        cache: any MediaCacheStore, watchdog: Duration = MediaFetcher.defaultWatchdog,
        retryDelays: [Duration] = MediaFetcher.defaultRetryDelays, clock: C,
        sleep: @escaping Sleeper = { try await Task.sleep(for: $0) }
    ) where C.Duration == Duration {
        self.cache = cache
        self.watchdog = watchdog
        self.retryDelays = retryDelays
        self.timer = MediaFetchTimer(clock)
        self.sleep = sleep
    }

    /// Fetches `offer` through `transport` and reports each state change to `onState`, and each
    /// automatic retry to `onRetry` before its wait begins.
    /// Only cancellation throws; every other end is an outcome.
    public func fetch(
        _ offer: LibraryMediaOffer,
        from transport: any LibraryTransport,
        admission: MediaCacheAdmission,
        onState: @escaping StateHandler = { _ in },
        onRetry: @escaping RetryHandler = { _ in }
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
        let delivered: URL
        switch try await deliverRetrying(offer, from: transport, admission: admission, onState: onState, onRetry: onRetry) {
        case let .file(url): delivered = url
        case let .ended(outcome): return outcome
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
            fetchLog.error("Audio for \(offer.entryID.rawValue, privacy: .public) could not be cached: \(MediaFetchErrorClassifier.logDescription(error), privacy: .public)")
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

    private enum Delivery {
        case file(URL)
        case ended(MediaFetchOutcome)
    }

    /// Asks the transport for the file, retrying a transient failure after each of `retryDelays`.
    /// A stall, a terminal error or the last failed attempt ends the fetch.
    private func deliverRetrying(
        _ offer: LibraryMediaOffer, from transport: any LibraryTransport, admission: MediaCacheAdmission,
        onState: @escaping StateHandler, onRetry: @escaping RetryHandler
    ) async throws -> Delivery {
        let attempts = retryDelays.count + 1
        var attempt = 1
        while true {
            onState(.awaiting)
            let error: Error
            do {
                return .file(try await deliver(offer, from: transport, onState: onState))
            } catch is StalledError {
                fetchLog.error("Audio for \(offer.entryID.rawValue, privacy: .public) stalled: no bytes for \(watchdog, privacy: .public)")
                return .ended(fail(.timedOut, onState))
            } catch is CancellationError {
                throw CancellationError()
            } catch let caught {
                error = caught
            }
            try Task.checkCancellation()
            let cause = MediaFetchErrorClassifier.failure(for: error)
            let detail = MediaFetchErrorClassifier.logDescription(error)
            guard attempt < attempts, MediaFetchErrorClassifier.isTransient(error) else {
                fetchLog.error("Audio for \(offer.entryID.rawValue, privacy: .public) failed on attempt \(attempt, privacy: .public) of \(attempts, privacy: .public) (\(cause.rawValue, privacy: .public)): \(detail, privacy: .public)")
                return .ended(fail(.deliveryFailed(cause.rawValue), onState))
            }
            let delay = Self.backoff(retryDelays[attempt - 1], after: error)
            attempt += 1
            fetchLog.notice("Audio for \(offer.entryID.rawValue, privacy: .public) failed transiently; attempt \(attempt, privacy: .public) of \(attempts, privacy: .public) in \(delay, privacy: .public): \(detail, privacy: .public)")
            onRetry(MediaFetchRetry(attempt: attempt, attempts: attempts, delay: delay, cause: cause))
            try await sleep(delay)
            try Task.checkCancellation()
            guard await liveAdmission(admission, offer: offer, transport: transport) else {
                return .ended(fail(.cacheFailed("Media admission changed"), onState))
            }
        }
    }

    /// One attempt: the transport's download raced against the stall watchdog. Progress starts
    /// from zero, because a new attempt downloads the whole file again.
    private func deliver(_ offer: LibraryMediaOffer, from transport: any LibraryTransport,
                         onState: @escaping StateHandler) async throws -> URL {
        let timer = timer, watchdog = watchdog
        let tracker = ProgressTracker(start: timer.now())
        let total = offer.byteCount
        return try await withThrowingTaskGroup(of: URL?.self) { group in
            group.addTask {
                try await transport.fetchMedia(offer) { bytes in
                    guard tracker.record(bytes, at: timer.now()) else { return }
                    onState(.downloading(bytes: bytes, total: total))
                }
            }
            group.addTask {
                try await Self.stall(tracker, after: watchdog, on: timer)
                return nil
            }
            defer { group.cancelAll() }
            for try await result in group {
                if let result { return result }
            }
            throw CancellationError()
        }
    }

    /// The wait before the next attempt: the scheduled step, or longer when a closed `TransportGate`
    /// said when it reopens (capped, so a long closure ends the fetch rather than hiding it).
    static func backoff(_ step: Duration, after error: Error) -> Duration {
        guard let throttled = error as? TransportThrottled else { return step }
        let wait = min(max(throttled.retryAt.timeIntervalSinceNow, 0), maximumThrottleWait)
        return max(step, .seconds(wait))
    }

    /// Returns only by throwing `StalledError` once no byte has arrived for `interval`,
    /// or `CancellationError` when the transfer finished first. Slow but steady progress keeps
    /// moving the deadline, so a long download never stalls while bytes still arrive. The time is
    /// read before the last progress, so a byte that lands between the two reads cannot look late.
    private static func stall(_ tracker: ProgressTracker, after interval: Duration, on timer: MediaFetchTimer) async throws {
        while true {
            let now = timer.now()
            let deadline = tracker.lastProgress + interval
            if now >= deadline { throw StalledError() }
            try await timer.sleep(deadline)
        }
    }
}

/// Thread-safe record of the last time the received byte count grew.
private final class ProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Int64 = 0
    private var last: Duration

    init(start: Duration) { last = start }

    var lastProgress: Duration {
        lock.lock()
        defer { lock.unlock() }
        return last
    }

    /// True when `received` is new progress.
    func record(_ received: Int64, at time: Duration) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard received > bytes else { return false }
        bytes = received
        last = time
        return true
    }
}
