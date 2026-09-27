import CryptoKit
import MediaPlayer
import XCTest
@testable import WiltediOS
import WiltedDomain
@testable import WiltedListener
import WiltedSync
import CloudKit
import WiltedCloudKit

actor LegacyAssetEngineDriver: CloudKitEngineDriver {
    nonisolated let events: AsyncStream<CloudKitEngineEvent>
    private let continuation: AsyncStream<CloudKitEngineEvent>.Continuation
    private let record: CKRecord
    private let holdRecordFetch: Bool
    private let recordFetchRelease: AsyncStream<Void>.Continuation
    private let recordFetchReleaseStream: AsyncStream<Void>
    private var requestedNames: [String] = []

    init(record: CKRecord, holdRecordFetch: Bool = false) {
        let (events, continuation) = AsyncStream<CloudKitEngineEvent>.makeStream()
        let (releaseStream, release) = AsyncStream<Void>.makeStream()
        self.events = events
        self.continuation = continuation
        self.record = record
        self.holdRecordFetch = holdRecordFetch
        self.recordFetchRelease = release
        self.recordFetchReleaseStream = releaseStream
    }

    func fetchChanges() async throws {}
    func fetchRecords(_ ids: [CKRecord.ID]) async throws -> [CKRecord] {
        requestedNames.append(contentsOf: ids.map(\.recordName))
        if holdRecordFetch {
            for await _ in recordFetchReleaseStream { break }
        }
        return ids.contains(record.recordID) ? [record] : []
    }
    func sendChanges() async throws {}
    func cancelOperations() async {}
    func addPendingRecordZoneChanges(_ changes: [CKSyncEngine.PendingRecordZoneChange]) async {}
    nonisolated func isValidStateData(_ data: Data) -> Bool { true }
    func requestedRecordNames() -> [String] { requestedNames }
    func emit(_ event: CloudKitEngineEvent) { continuation.yield(event) }
    func releaseRecordFetch() { recordFetchRelease.yield(()) }
    func waitForRecordFetch() async -> Bool {
        let clock = ContinuousClock()
        let end = clock.now + .seconds(5)
        while clock.now < end {
            if !requestedNames.isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return !requestedNames.isEmpty
    }
}

actor BlockingSyncTransport: SyncTransport {
    let statuses = AsyncStream<SyncStatus> { _ in }
    private var fetchCount = 0
    private var release: CheckedContinuation<Void, Never>?
    private var failReleasedFetch = false
    private var sent: [[SyncPendingChange]] = []

    func fetchChanges() async throws -> SyncFetchBatch {
        fetchCount += 1
        await withCheckedContinuation { continuation in
            release = continuation
        }
        if failReleasedFetch {
            failReleasedFetch = false
            throw TestSyncError.network
        }
        return try SyncFetchBatch(generationID: "refresh", records: [], engineState: Data([2]))
    }

    func save(changes: [SyncPendingChange], role: SyncDeviceRole) async throws -> SyncSendResult {
        sent.append(changes)
        return try SyncSendResult(engineState: Data([3]))
    }

    func fetchCountValue() -> Int { fetchCount }

    func releaseFetch(failing: Bool = false) {
        failReleasedFetch = failing
        release?.resume()
        release = nil
    }

    func savedChanges() -> [[SyncPendingChange]] { sent }
}

actor BlockingSaveSyncTransport: SyncTransport {
    nonisolated let statuses = AsyncStream<SyncStatus> { _ in }
    private var saveCount = 0
    private var saveWaiters: [CheckedContinuation<Void, Never>] = []

    func fetchChanges() async throws -> SyncFetchBatch {
        try SyncFetchBatch(generationID: "blocking-save-refresh", records: [], engineState: Data([2]))
    }

    func save(changes: [SyncPendingChange], role: SyncDeviceRole) async throws -> SyncSendResult {
        saveCount += 1
        await withCheckedContinuation { saveWaiters.append($0) }
        return try SyncSendResult(engineState: Data([3]))
    }

    func saveCountValue() -> Int { saveCount }

    func waitForSaveCount(_ expected: Int) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while saveCount < expected, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        return saveCount >= expected
    }

    func releaseNextSave() {
        guard !saveWaiters.isEmpty else { return }
        saveWaiters.removeFirst().resume()
    }
}

actor BlockingAssetLoader {
    private let sourceURL: URL
    private var requestCount = 0
    private var release: CheckedContinuation<Void, Never>?

    init() throws {
        sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wilted-blocking-asset-\(UUID().uuidString).m4a")
        try Data("wilted-second-play-audio".utf8).write(to: sourceURL, options: .atomic)
    }

    func load(recordID: WiltedRecordID, asset: WiltedAsset) async -> URL {
        requestCount += 1
        await withCheckedContinuation { release = $0 }
        return sourceURL
    }

    func waitUntilRequested() async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while requestCount == 0, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        return requestCount > 0
    }

    func releaseLoad() {
        release?.resume()
        release = nil
    }
}

enum TestSyncError: Error, LocalizedError, Sendable {
    case network

    var errorDescription: String? { "network unavailable" }
}

actor FailOnceChunkLoader {
    private let data: Data
    private var attempts = 0

    init(data: Data) { self.data = data }

    func load(itemID _: ItemID, revisionID _: RevisionID, manifest _: AudioChunkManifest) throws -> Data {
        attempts += 1
        guard attempts > 1 else { throw TestSyncError.network }
        return data
    }

    func attemptCount() -> Int { attempts }
}

final class AccountSignalSource: @unchecked Sendable {
    let stream: AsyncStream<ListenerAccountChange>
    private let continuation: AsyncStream<ListenerAccountChange>.Continuation

    init() {
        let (stream, continuation) = AsyncStream<ListenerAccountChange>.makeStream()
        self.stream = stream
        self.continuation = continuation
    }

    func send(_ change: ListenerAccountChange) { continuation.yield(change) }
}

actor MetadataCapture {
    private(set) var values: [ListenerMetadata?] = []
    func save(_ metadata: ListenerMetadata?) { values.append(metadata) }
    var last: ListenerMetadata? { values.last ?? nil }
}

struct TestSyncSession: ListenerSyncSession {
    let transport: any SyncTransport
    let assetLoader: ListenerAssetLoader
    let audioChunkLoader: ListenerAudioChunkLoader
    let accountChanges: AsyncStream<ListenerAccountChange>
    let cancelAction: @Sendable () async -> Void

    init(transport: any SyncTransport,
         accountChanges: AsyncStream<ListenerAccountChange>? = nil,
         audioChunkLoader: ListenerAudioChunkLoader? = nil,
         cancelAction: @escaping @Sendable () async -> Void = {}) {
        self.transport = transport
        self.assetLoader = { _, asset in throw ListenerError.cacheUnavailable(asset.assetID) }
        self.audioChunkLoader = audioChunkLoader ?? { _, _, _ in throw TestSyncError.network }
        self.accountChanges = accountChanges ?? AsyncStream { _ in }
        self.cancelAction = cancelAction
    }

    func cancel() async { await cancelAction() }
    func resetAfterAccountChange() async {}
}

/// Wires a real audio cache and playback controller around fake device I/O.
///
/// The engine, session, and now-playing surfaces are the only parts that need hardware,
/// so faking exactly those keeps the playback path itself under the Debug gate. That path
/// was previously reachable only on a device, which is how a first play that could never
/// construct its own state shipped.
@MainActor
struct PlaybackHarness {
    let model: WiltedListenerAppModel
    let itemID: ItemID
    let engine: FakeAudioEngine
    let metadataCapture: MetadataCapture
    let repository: StaticSyncRepository
    let secondItemID: ItemID?

    static func make(
        cachedPlaybackRevisionID: RevisionID? = nil,
        includeSecondItem: Bool = false,
        cacheSecondItem: Bool = true,
        transport: (any SyncTransport)? = nil,
        assetLoader: ListenerAssetLoader? = nil,
        backgroundSleeper: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        }
    ) async throws -> PlaybackHarness {
        let url = URL(string: "https://example.test/first-play")!
        let itemID = try ItemID.derive(from: url)
        let revisionID = try RevisionID(rawValue: "revision-first-play")
        let bytes = Data("wilted-first-play-audio".utf8)
        let contentHash = "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let asset = try WiltedAsset(assetID: "audio-first-play", contentHash: contentHash)
        let article = try Article(itemID: itemID, canonicalURL: url, title: "First play",
                                  source: "Test", createdAt: Timestamp(Date()))
        let revision = try AudioRevision(itemID: itemID, revisionID: revisionID, durationSeconds: 30,
                                         byteCount: Int64(bytes.count), contentHash: contentHash,
                                         mediaType: "audio/mp4", createdAt: Timestamp(Date()), schemaVersion: 1)
        let codec = WiltedRecordCodec()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wilted-playback-\(UUID().uuidString)", isDirectory: true)
        let cache = try ListenerAudioCache(rootURL: root)
        _ = try await cache.store(data: bytes, asset: asset)
        let engine = FakeAudioEngine(duration: 30)
        let controller = ListenerPlaybackController(cache: cache, engine: engine,
                                                    session: FakeAudioSession(), nowPlaying: FakeNowPlaying())
        let metadataCapture = MetadataCapture()
        let cachedPlayback = try cachedPlaybackRevisionID.map {
            try PlaybackState(itemID: itemID, revisionID: $0, sessionID: "stale-session", sequence: 7,
                              positionSeconds: 12, durationSeconds: 30, completed: false,
                              intent: .progress, deviceID: "iphone", updatedAt: Timestamp(Date()))
        }
        var records = [try codec.encode(article: article, currentRevisionID: revisionID),
                       try codec.encode(revision: revision, audioAsset: asset)]
        var secondItemID: ItemID?
        if includeSecondItem {
            let secondURL = URL(string: "https://example.test/second-play")!
            let secondID = try ItemID.derive(from: secondURL)
            let secondRevisionID = try RevisionID(rawValue: "revision-second-play")
            let secondBytes = Data("wilted-second-play-audio".utf8)
            let secondHash = "sha256:" + SHA256.hash(data: secondBytes).map { String(format: "%02x", $0) }.joined()
            let secondAsset = try WiltedAsset(assetID: "audio-second-play", contentHash: secondHash)
            let secondArticle = try Article(itemID: secondID, canonicalURL: secondURL, title: "Second play",
                                            source: "Test", createdAt: Timestamp(Date()))
            let secondRevision = try AudioRevision(itemID: secondID, revisionID: secondRevisionID,
                                                   durationSeconds: 30, byteCount: Int64(secondBytes.count),
                                                   contentHash: secondHash, mediaType: "audio/mp4",
                                                   createdAt: Timestamp(Date()), schemaVersion: 1)
            if cacheSecondItem {
                _ = try await cache.store(data: secondBytes, asset: secondAsset)
            }
            records.append(try codec.encode(article: secondArticle, currentRevisionID: secondRevisionID))
            records.append(try codec.encode(revision: secondRevision, audioAsset: secondAsset))
            secondItemID = secondID
        }
        if let cachedPlayback { records.append(try codec.encode(playback: cachedPlayback)) }
        let repository = StaticSyncRepository(state: SyncRepositoryState(
            records: records,
            engineState: Data([1])))
        return PlaybackHarness(model: WiltedListenerAppModel(
            repository: repository,
            transport: transport,
            cache: cache,
            playback: controller,
            assetLoader: assetLoader,
            metadataSaver: { metadata in await metadataCapture.save(metadata) },
            backgroundSleeper: backgroundSleeper
        ), itemID: itemID, engine: engine, metadataCapture: metadataCapture,
        repository: repository, secondItemID: secondItemID)
    }
}

final class FakeAudioEngine: ListenerAudioEngine, @unchecked Sendable {
    let duration: Double
    var currentTime: Double = 0
    private(set) var playing = false
    var allowsPlayback = true
    private(set) var loadCallCount = 0
    private(set) var playCallCount = 0
    private let loadGateLock = NSLock()
    private var nextLoadGate: LoadGate?
    private(set) var completionGeneration: UInt64 = 0
    private var completionHandler: (@Sendable (UInt64) -> Void)?
    var isPlaying: Bool { playing }
    init(duration: Double) { self.duration = duration }
    func holdNextLoad() -> LoadGate {
        let gate = LoadGate()
        loadGateLock.withLock { nextLoadGate = gate }
        return gate
    }
    func load(url: URL) throws {
        loadCallCount += 1
        let gate = loadGateLock.withLock {
            defer { nextLoadGate = nil }
            return nextLoadGate
        }
        gate?.started.signal()
        gate?.release.wait()
    }
    func load(url: URL, completionGeneration: UInt64) throws {
        try load(url: url)
        self.completionGeneration = completionGeneration
    }
    func play() -> Bool { playCallCount += 1; playing = allowsPlayback; return allowsPlayback }
    func pause() { playing = false }
    func installCompletionHandler(_ handler: @escaping @Sendable (UInt64) -> Void) { completionHandler = handler }
    func finishNaturally() {
        playing = false
        currentTime = duration
        completionHandler?(completionGeneration)
    }
    func fireCompletion(generation: UInt64) { completionHandler?(generation) }
}

actor BackgroundCheckpointSleeper {
    private var recorded: [Duration] = []
    private var waiters: [CheckedContinuation<Void, Error>] = []

    func sleep(for duration: Duration) async throws {
        recorded.append(duration)
        try await withCheckedThrowingContinuation { continuation in waiters.append(continuation) }
    }

    func waitUntilSleeping() async -> Duration? {
        let clock = ContinuousClock()
        let end = clock.now + .seconds(2)
        while clock.now < end {
            if let duration = recorded.last { return duration }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return recorded.last
    }

    func releaseOne() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume()
    }

    func sleepCount() -> Int { recorded.count }
}

actor AsyncEnqueueGate {
    private var started = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        started = true
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilStarted() async -> Bool {
        let clock = ContinuousClock()
        let end = clock.now + .seconds(2)
        while clock.now < end {
            if started { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return started
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

final class LoadGate: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    func waitUntilStarted() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [self] in
                continuation.resume(returning: started.wait(timeout: .now() + 2) == .success)
            }
        }
    }
}

struct FakeAudioSession: ListenerAudioSession {
    func activate() throws {}
    func deactivate() {}
}

struct FakeNowPlaying: ListenerNowPlaying {
    func update(title: String, duration: Double, position: Double, rate: Double) {}
    func clear() {}
}
