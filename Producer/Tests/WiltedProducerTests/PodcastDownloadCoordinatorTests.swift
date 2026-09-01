import CryptoKit
import Foundation
import Testing
import WiltedDomain
@testable import WiltedProducer

@Suite("Podcast download coordinator")
struct PodcastDownloadCoordinatorTests {
    @Test func enforcesHTTPSRedirectsAndHTTPStatus() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        await expect(.invalidURL, fixture: fixture, events: [
            .response(.init(url: URL(string: "http://cdn.example.test/e.mp3")!, statusCode: 200,
                            mediaType: "audio/mpeg", expectedByteCount: 3))
        ])
        let redirected = PodcastDownloadCoordinator(
            store: fixture.store, libraryDirectory: fixture.libraryDirectory,
            transport: FailingTransport(.insecureRedirect), mediaValidator: StubValidator(result: .success(12))
        )
        do { _ = try await redirected.download(episodeID: fixture.episodeID); Issue.record("expected redirect rejection") }
        catch { #expect(error as? PodcastDownloadCoordinatorError == .insecureRedirect) }
        await expect(.invalidResponse(503), fixture: fixture, events: [
            .response(.init(url: fixture.enclosureURL, statusCode: 503,
                            mediaType: "audio/mpeg", expectedByteCount: 3))
        ])
        #expect(try await fixture.store.revisions(for: fixture.episodeID).isEmpty)
    }

    @Test func enforcesDeclaredAndStreamedBounds() async throws {
        let declared = try await Fixture(declaredBytes: 11)
        defer { declared.remove() }
        await expect(.declaredSizeTooLarge(11), fixture: declared, maximumBytes: 10, events: [])

        let streamed = try await Fixture()
        defer { streamed.remove() }
        await expect(.declaredSizeTooLarge(11), fixture: streamed, maximumBytes: 10, events: [
            .response(.init(url: streamed.enclosureURL, statusCode: 200,
                            mediaType: "audio/mpeg", expectedByteCount: 11))
        ])
        await expect(.streamedSizeTooLarge(11), fixture: streamed, maximumBytes: 10, events: [
            .response(.init(url: streamed.enclosureURL, statusCode: 200,
                            mediaType: "audio/mpeg", expectedByteCount: nil)),
            .data(Data(repeating: 1, count: 6)), .data(Data(repeating: 2, count: 5))
        ])
        #expect(try stagingFiles(in: streamed.libraryDirectory).isEmpty)
    }

    @Test func treatsResponseLengthAsAuthoritativeForCompletionAndProgress() async throws {
        let fixture = try await Fixture(declaredBytes: 12)
        defer { fixture.remove() }
        let coordinator = fixture.coordinator(events: [
            .response(.init(url: fixture.enclosureURL, statusCode: 200,
                            mediaType: fixture.mediaType + "; charset=binary", expectedByteCount: 6)),
            .data(Data(fixture.body.prefix(3))), .data(Data(fixture.body.suffix(3)))
        ])
        let result = try await coordinator.download(episodeID: fixture.episodeID)
        #expect(result.download.bytesReceived == Int64(fixture.body.count))
        #expect(result.download.expectedByteCount == 6)
    }

    @Test func rejectsDownloadsWhenResponseLengthMismatchDetected() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        await expect(
            .declaredSizeMismatch(expected: 7, actual: 6), fixture: fixture, events: [
                .response(.init(url: fixture.enclosureURL, statusCode: 200,
                                mediaType: "audio/mpeg", expectedByteCount: 7)),
                .data(Data(fixture.body))
            ]
        )
    }

    @Test func rejectsUnsupportedAndMismatchedMIMEAfterParameterNormalization() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        await expect(.unsupportedMediaType("video/mp4"), fixture: fixture, events: [
            .response(.init(url: fixture.enclosureURL, statusCode: 200,
                            mediaType: "Video/MP4; charset=binary", expectedByteCount: nil))
        ])
        await expect(.mediaTypeMismatch(expected: "audio/mpeg", actual: "audio/mp4"), fixture: fixture, events: [
            .response(.init(url: fixture.enclosureURL, statusCode: 200,
                            mediaType: "AUDIO/MP4; charset=binary", expectedByteCount: nil))
        ])
    }

    @Test func rejectsInvalidAudioAndExpectedHashMismatch() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let events = fixture.successEvents
        let invalidAudio = PodcastDownloadCoordinator(
            store: fixture.store, libraryDirectory: fixture.libraryDirectory,
            transport: EventTransport(events), mediaValidator: StubValidator(result: .failure(.invalidAudio))
        )
        do { _ = try await invalidAudio.download(episodeID: fixture.episodeID); Issue.record("expected invalid audio") }
        catch { #expect(error as? PodcastDownloadCoordinatorError == .invalidAudio) }

        let mismatch = PodcastDownloadCoordinator(
            store: fixture.store, libraryDirectory: fixture.libraryDirectory,
            transport: EventTransport(events), mediaValidator: StubValidator(result: .success(12))
        )
        let expectedHash = "sha256:" + String(repeating: "0", count: 64)
        do { _ = try await mismatch.download(episodeID: fixture.episodeID, expectedContentHash: expectedHash); Issue.record("expected hash mismatch") }
        catch PodcastDownloadCoordinatorError.hashMismatch(let expected, let actual) {
            #expect(expected == expectedHash)
            #expect(actual == contentHash(fixture.body))
        } catch { Issue.record("unexpected error: \(error)") }
        #expect(try stagingFiles(in: fixture.libraryDirectory).isEmpty)
    }

    @Test func reportsKnownAndUnknownExpectedSizeProgress() async throws {
        let known = try await Fixture(declaredBytes: 6)
        defer { known.remove() }
        let knownProgress = ProgressRecorder()
        let knownCoordinator = known.coordinator(events: known.successEvents)
        _ = try await knownCoordinator.download(episodeID: known.episodeID) { knownProgress.append($0) }
        #expect(knownProgress.values.contains { $0.bytesReceived == 3 && $0.expectedByteCount == 6 })

        let unknown = try await Fixture()
        defer { unknown.remove() }
        let unknownProgress = ProgressRecorder()
        _ = try await unknown.coordinator(events: unknown.successEvents).download(episodeID: unknown.episodeID) {
            unknownProgress.append($0)
        }
        #expect(unknownProgress.values.contains { $0.bytesReceived == 3 && $0.expectedByteCount == nil })
        #expect(unknownProgress.values.last?.stage == .completed)
    }

    @Test func productionTransportHandlesRedirectsMetadataAndTermination() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DownloadURLProtocol.self]
        let transport = URLSessionPodcastDownloadTransport(configuration: configuration)
        var response: PodcastDownloadHTTPResponse?
        var body = Data()
        for try await event in transport.events(for: URL(string: "https://downloads.example.test/episode?case=redirect")!) {
            switch event {
            case .response(let value): response = value
            case .data(let data): body.append(data)
            }
        }
        #expect(response?.url.query == "case=success")
        #expect(response?.mediaType == "Audio/MP3; charset=binary")
        #expect(response?.expectedByteCount == nil)
        #expect(body == Data("audio".utf8))

        do {
            for try await _ in transport.events(for: URL(string: "https://downloads.example.test/episode?case=downgrade")!) {}
            Issue.record("expected insecure redirect rejection")
        } catch { #expect(error as? PodcastDownloadCoordinatorError == .insecureRedirect) }
    }

    @Test func acceptsFeedClientMP3AndM4AAliases() async throws {
        let mp3 = try await Fixture(mediaType: "audio/mp3")
        defer { mp3.remove() }
        let mp3Result = try await mp3.coordinator(events: mp3.successEvents).download(episodeID: mp3.episodeID)
        #expect(mp3Result.mediaURL.pathExtension == "mp3")

        let m4a = try await Fixture(mediaType: "audio/m4a")
        defer { m4a.remove() }
        let m4aResult = try await m4a.coordinator(events: m4a.successEvents).download(episodeID: m4a.episodeID)
        #expect(m4aResult.mediaURL.pathExtension == "m4a")
    }

    @Test func cancellationPersistsStateAndRemovesOwnedStaging() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let transport = CancellationTransport(response: .init(
            url: fixture.enclosureURL, statusCode: 200, mediaType: "audio/mpeg", expectedByteCount: nil
        ))
        let coordinator = PodcastDownloadCoordinator(
            store: fixture.store, libraryDirectory: fixture.libraryDirectory,
            transport: transport, mediaValidator: StubValidator(result: .success(12))
        )
        let task = Task { try await coordinator.download(episodeID: fixture.episodeID) }
        await transport.started.wait()
        task.cancel()
        do { _ = try await task.value; Issue.record("expected cancellation") }
        catch { #expect(error as? PodcastDownloadCoordinatorError == .cancelled) }
        #expect(try await fixture.store.download(for: fixture.episodeID)?.status == .cancelled)
        #expect(try stagingFiles(in: fixture.libraryDirectory).isEmpty)
    }

    @Test func cancellationAfterLastChunkCannotReachValidationOrPublication() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let canceller = TaskCanceller()
        let validationCalls = CallCounter()
        let coordinator = PodcastDownloadCoordinator(
            store: fixture.store, libraryDirectory: fixture.libraryDirectory,
            transport: EventTransport(fixture.successEvents),
            mediaValidator: CountingValidator(counter: validationCalls)
        )
        let task = Task {
            try await coordinator.download(episodeID: fixture.episodeID) { progress in
                if progress.stage == .transferring, progress.bytesReceived == Int64(fixture.body.count) {
                    canceller.requestCancel()
                }
            }
        }
        canceller.install { task.cancel() }
        do { _ = try await task.value; Issue.record("expected end-of-stream cancellation") }
        catch { #expect(error as? PodcastDownloadCoordinatorError == .cancelled) }
        #expect(await validationCalls.value == 0)
        #expect(try await fixture.store.revisions(for: fixture.episodeID).isEmpty)
        #expect(try stagingFiles(in: fixture.libraryDirectory).isEmpty)
    }

    @Test func atomicallyCompletesAndRepeatedImportIsIdempotent() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let counter = CallCounter()
        let coordinator = PodcastDownloadCoordinator(
            store: fixture.store, libraryDirectory: fixture.libraryDirectory,
            transport: EventTransport(fixture.successEvents, counter: counter),
            mediaValidator: StubValidator(result: .success(12)), now: { Date(timeIntervalSince1970: 1_700_000_100) }
        )
        let first = try await coordinator.download(episodeID: fixture.episodeID)
        let repeatedProgress = ProgressRecorder()
        let second = try await coordinator.download(episodeID: fixture.episodeID) { repeatedProgress.append($0) }
        #expect(first == second)
        #expect(await counter.value == 1)
        #expect(repeatedProgress.values.contains { $0.stage == .verifying && $0.bytesReceived == 6 })
        #expect(try Data(contentsOf: first.mediaURL) == fixture.body)
        #expect(try await fixture.store.readyRevision(for: fixture.episodeID)?.revision == first.revision)
        #expect(try await fixture.store.download(for: fixture.episodeID) == first.download)
        #expect(try stagingFiles(in: fixture.libraryDirectory).isEmpty)
    }

    @Test func idempotencyRehashIsCancellableBeforeQueuedState() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let largeBody = Data(repeating: 0x5a, count: 8 * 1_024 * 1_024)
        let prior = try await fixture.installCompleted(body: largeBody)
        let canceller = TaskCanceller()
        let coordinator = fixture.coordinator(events: [])
        let task = Task {
            try await coordinator.download(episodeID: fixture.episodeID) { progress in
                if progress.stage == .verifying { canceller.requestCancel() }
            }
        }
        canceller.install { task.cancel() }
        do { _ = try await task.value; Issue.record("expected verification cancellation") }
        catch { #expect(error as? PodcastDownloadCoordinatorError == .cancelled) }
        #expect(try Data(contentsOf: prior.mediaURL) == largeBody)
        #expect(try await fixture.store.readyRevision(for: fixture.episodeID) == prior)
        #expect(try await fixture.store.download(for: fixture.episodeID)?.status == .completed)
        #expect(try stagingFiles(in: fixture.libraryDirectory).isEmpty)
    }

    @Test func failedRedownloadPreservesPriorMediaAndRevision() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let first = try await fixture.coordinator(events: fixture.successEvents).download(episodeID: fixture.episodeID)
        let priorData = try Data(contentsOf: first.mediaURL)
        let differentExpected = "sha256:" + String(repeating: "f", count: 64)
        do {
            _ = try await fixture.coordinator(events: fixture.successEvents).download(
                episodeID: fixture.episodeID, expectedContentHash: differentExpected
            )
            Issue.record("expected failure")
        } catch { #expect(error is PodcastDownloadCoordinatorError) }
        #expect(try Data(contentsOf: first.mediaURL) == priorData)
        #expect(try await fixture.store.revisions(for: fixture.episodeID).map(\.revision) == [first.revision])
        #expect(try await fixture.store.download(for: fixture.episodeID)?.status == .failed)
        #expect(try stagingFiles(in: fixture.libraryDirectory).isEmpty)
    }

    @Test func cancelledRedownloadPreservesPriorMediaAndRevision() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let first = try await fixture.coordinator(events: fixture.successEvents).download(episodeID: fixture.episodeID)
        let priorData = try Data(contentsOf: first.mediaURL)
        let priorRevision = try #require(try await fixture.store.readyRevision(for: fixture.episodeID))
        let transport = CancellationTransport(response: .init(
            url: fixture.enclosureURL, statusCode: 200, mediaType: fixture.mediaType, expectedByteCount: nil
        ))
        let coordinator = PodcastDownloadCoordinator(
            store: fixture.store, libraryDirectory: fixture.libraryDirectory, transport: transport,
            mediaValidator: StubValidator(result: .success(12))
        )
        let differentExpected = "sha256:" + String(repeating: "e", count: 64)
        let task = Task {
            try await coordinator.download(episodeID: fixture.episodeID, expectedContentHash: differentExpected)
        }
        await transport.started.wait()
        task.cancel()
        do { _ = try await task.value; Issue.record("expected cancellation") }
        catch { #expect(error as? PodcastDownloadCoordinatorError == .cancelled) }
        #expect(try Data(contentsOf: first.mediaURL) == priorData)
        #expect(try await fixture.store.readyRevision(for: fixture.episodeID) == priorRevision)
        #expect(try stagingFiles(in: fixture.libraryDirectory).isEmpty)
    }

    private func expect(
        _ expected: PodcastDownloadCoordinatorError,
        fixture: Fixture,
        maximumBytes: Int64 = PodcastDownloadCoordinator.maximumDownloadBytes,
        events: [PodcastDownloadEvent]
    ) async {
        let coordinator = fixture.coordinator(events: events, maximumBytes: maximumBytes)
        do { _ = try await coordinator.download(episodeID: fixture.episodeID); Issue.record("expected \(expected)") }
        catch { #expect(error as? PodcastDownloadCoordinatorError == expected) }
    }
}

private final class Fixture: @unchecked Sendable {
    let root: URL
    let libraryDirectory: URL
    let store: LocalLibraryStore
    let episodeID: ItemID
    let enclosureURL: URL
    let body = Data("abcdef".utf8)
    let declaredBytes: Int64?
    let mediaType: String

    init(declaredBytes: Int64? = nil, mediaType: String = "audio/mpeg") async throws {
        self.declaredBytes = declaredBytes
        self.mediaType = mediaType
        enclosureURL = URL(string: "https://cdn.example.test/episode")!
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        libraryDirectory = root.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
        store = try LocalLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let feedURL = URL(string: "https://podcasts.example.test/feed.xml")!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        episodeID = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "episode-1", enclosureURL: enclosureURL)
        let episode = try PodcastEpisode(
            itemID: episodeID, feedID: feedID, feedURL: feedURL, rssGUID: "episode-1", title: "Episode",
            enclosureURL: enclosureURL, enclosureMediaType: mediaType, enclosureByteCount: declaredBytes,
            createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        )
        try await store.save(episode: episode)
    }

    var successEvents: [PodcastDownloadEvent] {
        [.response(.init(url: enclosureURL, statusCode: 200, mediaType: mediaType + "; charset=binary",
                         expectedByteCount: declaredBytes)),
         .data(Data(body.prefix(3))), .data(Data(body.suffix(3)))]
    }

    func coordinator(events: [PodcastDownloadEvent], maximumBytes: Int64 = PodcastDownloadCoordinator.maximumDownloadBytes) -> PodcastDownloadCoordinator {
        PodcastDownloadCoordinator(
            store: store, libraryDirectory: libraryDirectory, transport: EventTransport(events),
            mediaValidator: StubValidator(result: .success(12)), maximumBytes: maximumBytes,
            now: { Date(timeIntervalSince1970: 1_700_000_100) }
        )
    }

    func installCompleted(body: Data) async throws -> StoredAudioRevision {
        let hash = contentHash(body)
        let revisionID = try RevisionID.derive(downloadedAudioContentHash: hash)
        let mediaURL = libraryDirectory.appendingPathComponent("prior-large.mp3")
        try body.write(to: mediaURL)
        let revision = try AudioRevision(
            itemID: episodeID, revisionID: revisionID, durationSeconds: 12,
            byteCount: Int64(body.count), contentHash: hash, mediaType: mediaType,
            createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_200)), schemaVersion: 3
        )
        let download = try PodcastDownload(
            episodeID: episodeID, status: .completed, bytesReceived: Int64(body.count),
            localURL: mediaURL, contentHash: hash,
            updatedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_200))
        )
        try await store.finalizePodcastDownload(revision: revision, mediaURL: mediaURL, download: download)
        return StoredAudioRevision(revision: revision, mediaURL: mediaURL)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private struct EventTransport: PodcastDownloadTransporting {
    let suppliedEvents: [PodcastDownloadEvent]
    let counter: CallCounter?

    init(_ events: [PodcastDownloadEvent], counter: CallCounter? = nil) {
        suppliedEvents = events; self.counter = counter
    }

    func events(for url: URL) -> AsyncThrowingStream<PodcastDownloadEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await counter?.increment()
                for event in suppliedEvents { continuation.yield(event) }
                continuation.finish()
            }
        }
    }
}

private struct FailingTransport: PodcastDownloadTransporting {
    let error: PodcastDownloadCoordinatorError
    init(_ error: PodcastDownloadCoordinatorError) { self.error = error }
    func events(for url: URL) -> AsyncThrowingStream<PodcastDownloadEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: error) }
    }
}

private struct StubValidator: PodcastMediaValidating {
    let result: Result<Double, PodcastDownloadCoordinatorError>
    func duration(of url: URL, onStatus: @escaping @Sendable (String) -> Void) async throws -> Double {
        onStatus("validating")
        return try result.get()
    }
}

private struct CountingValidator: PodcastMediaValidating {
    let counter: CallCounter
    func duration(of url: URL, onStatus: @escaping @Sendable (String) -> Void) async throws -> Double {
        await counter.increment()
        return 12
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [PodcastDownloadProgress] = []
    var values: [PodcastDownloadProgress] { lock.withLock { storage } }
    func append(_ value: PodcastDownloadProgress) { lock.withLock { storage.append(value) } }
}

private actor CallCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private final class TaskCanceller: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellation: (@Sendable () -> Void)?
    private var requested = false

    func install(_ cancellation: @escaping @Sendable () -> Void) {
        let cancelNow = lock.withLock {
            self.cancellation = cancellation
            return requested
        }
        if cancelNow { cancellation() }
    }

    func requestCancel() {
        let cancellation = lock.withLock {
            requested = true
            return self.cancellation
        }
        cancellation?()
    }
}

private struct CancellationTransport: PodcastDownloadTransporting {
    let response: PodcastDownloadHTTPResponse
    let started = AsyncGate()

    func events(for url: URL) -> AsyncThrowingStream<PodcastDownloadEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.response(response))
            Task { await started.open() }
        }
    }
}

private final class DownloadURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "downloads.example.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let requestCase = request.url?.query ?? ""
        if requestCase == "case=redirect" || requestCase == "case=downgrade" {
            let target = URL(string: requestCase == "case=redirect"
                ? "https://downloads.example.test/episode?case=success"
                : "http://downloads.example.test/episode?case=success")!
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1",
                headerFields: ["Location": target.absoluteString]
            )!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "Audio/MP3; charset=binary"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("audio".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func open() { isOpen = true; waiters.forEach { $0.resume() }; waiters.removeAll() }
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private func contentHash(_ data: Data) -> String {
    "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func stagingFiles(in library: URL) throws -> [URL] {
    let staging = library.appendingPathComponent(".podcast-staging", isDirectory: true)
    guard FileManager.default.fileExists(atPath: staging.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
}
