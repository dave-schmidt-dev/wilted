import Foundation
import OSLog
import WiltedDomain
import WiltedLibrary

#if canImport(WiltedProducer)
import WiltedProducer
#endif

private let queueLog = Logger(subsystem: "com.zerodelta.wilted", category: "MacMediaUploadQueue")

/// Durable queue of media requests the Mac has been asked to upload.
///
/// A request is saved here, keyed by intent id, before the intent ledger records it, so a crash
/// between the two writes loses nothing. An upload that fails transiently (throttle, network,
/// zone busy, service unavailable) stays queued and retries when the transport gate allows,
/// until `WiltedMacMediaService.maximumIntentAge` after the request was made; a permanent error,
/// or a request that outlives that age, is failed. The queue is replayed once per launch.
/// Quitting ends every wait (W-INV-019); the request stays queued and is served on the next launch.
actor WiltedMacMediaUploadQueue {
    /// Writes the queue bytes to its file and reports whether the folder sync is certain.
    typealias Writer = @Sendable (Data, URL) throws -> DurableFile.ReplacementResult
    /// Told each stage of a request, so the requesting device can show it.
    typealias RequestReporter = @Sendable (LibraryIntent, LibraryMediaRequestStatus.Stage, String?) async -> Void
    /// One attempt to serve a request; `isRetry` is true after a failed attempt in this run.
    typealias Attempt = @Sendable (LibraryIntent, _ isRetry: Bool) async throws -> Void

    /// The longest wait between two attempts that failed for a reason other than a throttle.
    static let maximumRetryDelay: Duration = .seconds(15 * 60)
    /// What the requesting device is told while the upload waits for iCloud.
    static let waitingDetail = "waiting for iCloud"

    /// The queue file's contents.
    struct Stored: Codable {
        var version = 1
        var intents: [LibraryIntent]
    }

    private let fileURL: URL?
    private let write: Writer
    private let now: @Sendable () -> Date
    private let retryDelay: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private let reportRequest: RequestReporter?
    private let attempt: Attempt

    private var queued: [String: LibraryIntent] = [:]
    private var running: [String: Task<Void, Never>] = [:]
    private var waits: [String: Task<Void, Error>] = [:]
    private var endingWaits = false

    /// `fileURL` nil keeps the queue in memory only. An unreadable file is set aside as
    /// `.corrupt`, never overwritten, and the queue starts empty. Nothing runs until `resumeAll()`
    /// or `admit(_:)`.
    init(
        fileURL: URL?,
        now: @escaping @Sendable () -> Date = { Date() },
        uploadRetryDelay: Duration = WiltedMacMediaService.defaultUploadRetryDelay,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        reportRequest: RequestReporter? = nil,
        write: @escaping Writer = { try DurableFile.replace($0, to: $1) },
        attempt: @escaping Attempt
    ) {
        self.fileURL = fileURL
        self.now = now
        retryDelay = uploadRetryDelay
        self.sleep = sleep
        self.reportRequest = reportRequest
        self.write = write
        self.attempt = attempt
        if let fileURL, let data = try? Data(contentsOf: fileURL) {
            if let stored = try? JSONDecoder().decode(Stored.self, from: data) {
                for intent in stored.intents { queued[intent.id] = intent }
            } else {
                let aside = fileURL.appendingPathExtension("corrupt")
                try? FileManager.default.removeItem(at: aside)
                try? FileManager.default.moveItem(at: fileURL, to: aside)
                queueLog.error("Upload queue was unreadable and was set aside")
            }
        }
    }

    var queuedCount: Int { queued.count }

    /// Every request still queued, oldest first.
    var queuedIntents: [LibraryIntent] { queued.values.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) } }

    func contains(_ id: String) -> Bool { queued[id] != nil }

    /// Saves `intent` and starts serving it, returning the task that settles it. An id already
    /// queued is not queued again: its running task is returned, or one is started. Throws, with
    /// nothing queued, when the save failed; the caller must then not record the intent.
    func admit(_ intent: LibraryIntent) throws -> Task<Void, Never> {
        if queued[intent.id] == nil {
            queued[intent.id] = intent
            do { try persist() } catch {
                queued[intent.id] = nil
                throw error
            }
        }
        return start(intent)
    }

    /// Starts the upload of a request that is queued but not running (after a quit, or the launch
    /// replay). Nil when the id is not queued.
    func resume(_ id: String) -> Task<Void, Never>? {
        queued[id].map { start($0) }
    }

    /// Replays the queue: starts every queued request that is not already running.
    func resumeAll() {
        for intent in queuedIntents { start(intent) }
    }

    /// Waits for every running request to settle, like `drain()`, but ends any wait for a retry
    /// at once. A request that is waiting stays queued for the next launch.
    func drainEndingThrottleWaits() async {
        endingWaits = true
        for wait in waits.values { wait.cancel() }
        await drain()
        endingWaits = false
    }

    /// Waits for every running request to settle.
    func drain() async {
        for task in Array(running.values) { await task.value }
    }

    @discardableResult
    private func start(_ intent: LibraryIntent) -> Task<Void, Never> {
        if let existing = running[intent.id] { return existing }
        let task = Task { await self.serve(intent) }
        running[intent.id] = task
        return task
    }

    /// Attempts `intent` until it is served, fails, or the queue is told to stop.
    private func serve(_ intent: LibraryIntent) async {
        defer { running[intent.id] = nil }
        var failures = 0, backoffs = 0
        while !endingWaits {
            guard now().timeIntervalSince(intent.createdAt) <= WiltedMacMediaService.maximumIntentAge else {
                queueLog.notice("A queued media request outlived its age limit and was failed")
                await settle(intent, failure: true)
                return
            }
            do {
                try await attempt(intent, failures > 0)
                await settle(intent, failure: false)
                return
            } catch is CancellationError {
                return
            } catch where MediaFetchErrorClassifier.isTransient(error) {
                failures += 1
                queueLog.notice("A media upload failed transiently (\(WiltedMacMediaService.typedCause(error), privacy: .public)); it stays queued")
                if failures == 1 { await reportRequest?(intent, .sending, Self.waitingDetail) }
                if !(error is TransportThrottled) { backoffs += 1 }
                guard await wait(delay(after: error, backoffs: backoffs), for: intent.id) else { return }
            } catch {
                queueLog.error("A media upload failed for good: \(WiltedMacMediaService.typedCause(error), privacy: .public)")
                await settle(intent, failure: true)
                return
            }
        }
    }

    /// The time to pass before the next attempt: until a throttle lifts, else a doubling delay
    /// that a throttle does not lengthen.
    private func delay(after error: Error, backoffs: Int) -> Duration {
        if let throttled = error as? TransportThrottled {
            return .seconds(max(throttled.retryAt.timeIntervalSince(now()), 1))
        }
        return min(retryDelay * (1 << min(max(backoffs - 1, 0), 10)), Self.maximumRetryDelay)
    }

    /// Passes `duration`; false when the wait was ended early because the app is quitting.
    private func wait(_ duration: Duration, for id: String) async -> Bool {
        let sleep = self.sleep
        let pause = Task { try await sleep(duration) }
        waits[id] = pause
        defer { waits[id] = nil }
        if endingWaits { pause.cancel() }
        do { try await pause.value } catch { return false }
        return !endingWaits
    }

    /// Takes a finished request out of the queue, telling its device when it failed.
    private func settle(_ intent: LibraryIntent, failure: Bool) async {
        queued[intent.id] = nil
        do { try persist() } catch {
            queueLog.error("Upload queue could not save a finished request; it may be served again: \(String(describing: error), privacy: .public)")
        }
        if failure { await reportRequest?(intent, .failed, WiltedMacMediaService.failedDetail) }
    }

    private func persist() throws {
        guard let fileURL else { return }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Stored(intents: queuedIntents))
        if case let .replacedDirectorySyncUncertain(failure) = try write(data, fileURL) {
            queueLog.warning("Upload queue landed but its folder sync is uncertain: \(failure.description, privacy: .public)")
        }
    }
}
