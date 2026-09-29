import CryptoKit
import Foundation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

enum StartupTestError: Error {
    case expectedFailure
}

actor BootstrapGate {
    private var held = false
    private var holdContinuation: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []

    func hold() async {
        held = true
        observers.forEach { $0.resume() }
        observers.removeAll()
        await withCheckedContinuation { holdContinuation = $0 }
    }

    func waitUntilHeld() async {
        if held { return }
        await withCheckedContinuation { observers.append($0) }
    }

    func release() {
        holdContinuation?.resume()
        holdContinuation = nil
    }
}

actor StoreCapture {
    private(set) var store: LocalLibraryStore?
    func capture(_ store: LocalLibraryStore) { self.store = store }
}

@MainActor
extension WiltedMacModel {
    /// Seeds Menu membership for a pure projection fixture without claiming a
    /// durable Feed decision was exercised.
    func seedPodcastQueueMembershipForTesting(_ episode: WiltedMacEpisode) {
        podcastQueueIDs.append(episode.id)
    }
}

@MainActor
func waitForFeedDecisionWriters(_ model: WiltedMacModel) async {
    let writers = Array(model.subscriptionWriteTasks.values)
    for writer in writers {
        await writer.value
    }
}

actor FailingBootstrap {
    private(set) var attempts = 0

    func run(at url: URL) throws -> LocalLibraryStore {
        attempts += 1
        if attempts == 1 {
            let retainedDirectory = url.deletingLastPathComponent()
                .appendingPathComponent("\(url.lastPathComponent).v5-test", isDirectory: true)
            try FileManager.default.createDirectory(at: retainedDirectory, withIntermediateDirectories: true)
            try Data("retained-v5".utf8).write(to: retainedDirectory.appendingPathComponent(url.lastPathComponent))
        }
        throw StartupTestError.expectedFailure
    }
}

actor SuccessfulBootstrap {
    private(set) var attempts = 0

    func run(at url: URL) throws -> LocalLibraryStore {
        attempts += 1
        return try LocalLibraryStore(url: url)
    }
}

@MainActor
final class ModelTestNowPlayingSink: WiltedNowPlayingSink {
    func publish(_ info: WiltedNowPlayingInfo) {}
    func clear() {}
}

@MainActor
final class ModelTestRemoteCommandSource: WiltedRemoteCommandSource {
    private var handler: (@MainActor (WiltedRemoteCommand) -> Void)?
    private(set) var availability: [(hasNext: Bool, hasPrevious: Bool)] = []

    func install(handler: @escaping @MainActor (WiltedRemoteCommand) -> Void) { self.handler = handler }
    func updateQueueAvailability(hasNext: Bool, hasPrevious: Bool) {
        availability.append((hasNext: hasNext, hasPrevious: hasPrevious))
    }
    func send(_ command: WiltedRemoteCommand) { handler?(command) }
}

/// Seeds one downloaded, prepared episode -- unplayed and not queued -- so a
/// model that bootstraps this store sees it as a candidate for automatic Menu
/// admission.
func installPreparedMenuEpisode(
    into store: LocalLibraryStore, directory: URL, suffix: String,
    durationSeconds: TimeInterval = 12, playbackSeconds: TimeInterval = 0
) async throws -> ItemID {
    let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
    let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/menu-admission-\(suffix).xml"))
    let feedID = try ItemID.derivePodcastFeed(from: feedURL)
    let enclosure = try XCTUnwrap(URL(string: "https://media.example.test/menu-admission-\(suffix).mp3"))
    let episodeID = try ItemID.derivePodcastEpisode(
        feedURL: feedURL, rssGUID: "menu-admission-\(suffix)", enclosureURL: enclosure
    )
    try await store.save(feed: try PodcastFeed(
        itemID: feedID, canonicalURL: feedURL, title: "Menu admission feed", createdAt: created
    ))
    try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
    try await store.save(episode: try PodcastEpisode(
        itemID: episodeID, feedID: feedID, feedURL: feedURL, rssGUID: "menu-admission-\(suffix)",
        title: "Menu admission episode", publishedTime: created, enclosureURL: enclosure,
        enclosureMediaType: "audio/mpeg", createdAt: created
    ))
    let revisionID = try RevisionID(rawValue: "rev-" + String(repeating: "a", count: 64))
    let mediaURL = directory.appendingPathComponent("menu-admission-\(suffix).mp3")
    try Data("audio".utf8).write(to: mediaURL)
    try await store.finalizePodcastDownload(
        revision: try AudioRevision(
            itemID: episodeID, revisionID: revisionID, durationSeconds: durationSeconds, byteCount: 5,
            contentHash: "sha256:" + String(repeating: "a", count: 64),
            mediaType: "audio/mpeg", createdAt: created, schemaVersion: 3
        ),
        mediaURL: mediaURL,
        download: try PodcastDownload(
            episodeID: episodeID, status: .completed, bytesReceived: 5, expectedByteCount: 5,
            localURL: mediaURL, contentHash: "sha256:" + String(repeating: "a", count: 64),
            updatedAt: created
        )
    )
    try await store.savePreparationOutcome(PodcastPreparationOutcome(
        episodeID: episodeID, revisionID: revisionID, policyDigest: "d",
        pipelineFingerprint: "f", semanticVersion: "v", producedAt: created
    ))
    if playbackSeconds > 0 {
        try await store.save(playback: try PlaybackState(
            itemID: episodeID, revisionID: revisionID, sessionID: "prepared-menu-fixture",
            sequence: 1, positionSeconds: playbackSeconds, durationSeconds: durationSeconds,
            completed: false, intent: .progress, deviceID: "mac-test", updatedAt: created
        ))
    }
    return episodeID
}

struct FixedBodyLoader: PodcastFeedLoading {
    let body: Data
    func load(_ url: URL, maximumBytes: Int) async throws -> PodcastFeedHTTPResponse {
        PodcastFeedHTTPResponse(url: url, statusCode: 200, data: body)
    }
}

struct StrictPrefixBodyLoader: PodcastFeedLoading {
    let body: Data

    func load(_ url: URL, maximumBytes: Int) async throws -> PodcastFeedHTTPResponse {
        guard body.count <= maximumBytes else { throw PodcastFeedClientError.responseTooLarge }
        return PodcastFeedHTTPResponse(url: url, statusCode: 200, data: body)
    }

    func loadPrefix(_ url: URL, maximumBytes: Int) async throws -> PodcastFeedHTTPResponse {
        PodcastFeedHTTPResponse(url: url, statusCode: 200, data: Data(body.prefix(maximumBytes)))
    }
}

struct RedirectingBodyLoader: PodcastFeedLoading {
    let body: Data
    let finalURL: URL

    func load(_ url: URL, maximumBytes: Int) async throws -> PodcastFeedHTTPResponse {
        PodcastFeedHTTPResponse(url: finalURL, statusCode: 200, data: body)
    }
}

/// Serves a document per URL, but only once released.
///
/// Holding every request open is what lets a test place two classifications in
/// flight at a chosen moment instead of racing them.
actor GatedRoutingLoader: PodcastFeedLoading {
    private let documents: [URL: Data]
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = false

    init(documents: [URL: Data]) { self.documents = documents }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func load(_ url: URL, maximumBytes: Int) async throws -> PodcastFeedHTTPResponse {
        if !released {
            await withCheckedContinuation { waiters.append($0) }
        }
        guard let body = documents[url] else { throw URLError(.fileDoesNotExist) }
        return PodcastFeedHTTPResponse(url: url, statusCode: 200, data: body)
    }
}

struct FailingLoader: PodcastFeedLoading {
    func load(_ url: URL, maximumBytes: Int) async throws -> PodcastFeedHTTPResponse {
        throw URLError(.cannotConnectToHost)
    }
}

/// Replays a fixed event sequence instead of opening a real network connection.
struct StubPodcastDownloadTransport: PodcastDownloadTransporting {
    let events: [PodcastDownloadEvent]
    func events(for url: URL) -> AsyncThrowingStream<PodcastDownloadEvent, Error> {
        AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

/// Reports a fixed duration instead of decoding real audio, so a stub
/// transport's placeholder bytes can pass validation.
struct StubPodcastMediaValidator: PodcastMediaValidating {
    let duration: Double
    func duration(of url: URL, onStatus: @escaping @Sendable (String) -> Void) async throws -> Double {
        onStatus("stage=stub-validation")
        return duration
    }
}

struct CancellingPodcastPipelineRunner: PodcastPipelineRunning {
    func run(
        request: Data,
        onProgress: @escaping @Sendable (PodcastPreparationProgress) -> Void
    ) async throws -> Data {
        throw CancellationError()
    }
}

/// Suspends once the pipeline actually invokes it, and stays suspended until
/// `resume` is called. Used where a test needs to observe a run at the exact
/// moment it is admitted -- before it does any work -- without racing a
/// timer against however long the pipeline takes to fail on its own.
actor BlockingPodcastPipelineRunner: PodcastPipelineRunning {
    private var continuation: CheckedContinuation<Data, Error>?

    func run(
        request: Data,
        onProgress: @escaping @Sendable (PodcastPreparationProgress) -> Void
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func resume(throwing error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

/// Always answers with a bad HTTP status, which the coordinator turns into
/// `.invalidResponse` -- retryable per the Phase 3 classification -- without
/// needing a real network failure to produce one.
struct FailingPodcastDownloadTransport: PodcastDownloadTransporting {
    let enclosureURL: URL
    let statusCode: Int
    func events(for url: URL) -> AsyncThrowingStream<PodcastDownloadEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.response(.init(url: enclosureURL, statusCode: statusCode,
                                               mediaType: "audio/mpeg", expectedByteCount: nil)))
            continuation.finish()
        }
    }
}

/// Counts every attempt across the whole download, not just the failing ones,
/// so a test can prove exactly how many times automation's bounded retry
/// actually called into the transport.
final class DownloadAttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

/// Counts calls made through the one method the seam exposes. Consulted only
/// from `loadLibrary`, which runs on the model's own main actor, so this
/// needs no locking of its own.
final class CountingMediaAvailabilityChecker: WiltedMacMediaAvailabilityChecking {
    private(set) var fileExistsCallCount = 0
    func fileExists(atPath path: String) -> Bool {
        fileExistsCallCount += 1
        return FileManager.default.fileExists(atPath: path)
    }
}

struct CountingFailingPodcastDownloadTransport: PodcastDownloadTransporting {
    let enclosureURL: URL
    let statusCode: Int
    let counter: DownloadAttemptCounter
    func events(for url: URL) -> AsyncThrowingStream<PodcastDownloadEvent, Error> {
        counter.increment()
        return AsyncThrowingStream { continuation in
            continuation.yield(.response(.init(url: enclosureURL, statusCode: statusCode,
                                               mediaType: "audio/mpeg", expectedByteCount: nil)))
            continuation.finish()
        }
    }
}

/// A fixed successful event sequence that counts how many times it was asked
/// for -- used to prove a terminal (non-retryable) failure downstream of a
/// clean transfer makes exactly one attempt rather than a bounded retry's
/// several.
struct CountingPodcastDownloadTransport: PodcastDownloadTransporting {
    let counter: DownloadAttemptCounter
    let events: [PodcastDownloadEvent]
    func events(for url: URL) -> AsyncThrowingStream<PodcastDownloadEvent, Error> {
        counter.increment()
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

private actor ConcurrencyTracker {
    private var inFlight = 0
    private(set) var peak = 0
    func enter() { inFlight += 1; peak = max(peak, inFlight) }
    func leave() { inFlight -= 1 }
}

/// Delays every response briefly and tracks the peak number of transfers in
/// flight at once, so a test can prove bootstrap recovery serializes
/// downloads instead of firing one task per forced-redownload episode. The
/// delay gives an incorrectly-unbounded caller room to start a second
/// transfer before the first finishes.
final class ConcurrencyTrackingPodcastDownloadTransport: PodcastDownloadTransporting, Sendable {
    private let tracker = ConcurrencyTracker()
    let eventsByURL: [URL: [PodcastDownloadEvent]]

    init(eventsByURL: [URL: [PodcastDownloadEvent]]) { self.eventsByURL = eventsByURL }

    var maxObservedInFlight: Int {
        get async { await tracker.peak }
    }

    func events(for url: URL) -> AsyncThrowingStream<PodcastDownloadEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await self.tracker.enter()
                try? await Task.sleep(for: .milliseconds(50))
                for event in self.eventsByURL[url] ?? [] { continuation.yield(event) }
                continuation.finish()
                await self.tracker.leave()
            }
        }
    }
}

/// Holds a resolution open until the test releases it.
actor FingerprintGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        let resumed = waiters
        waiters = []
        for continuation in resumed { continuation.resume() }
    }
}

/// Records every fingerprint invalidation was asked to compare against.
actor FingerprintRecorder {
    private(set) var values: [String] = []
    func record(_ value: String) { values.append(value) }
}
