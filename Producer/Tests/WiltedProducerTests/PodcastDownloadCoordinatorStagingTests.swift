import Foundation
import Testing
import WiltedDomain
@testable import WiltedProducer

/// `stageOriginal` fetches an episode's original for a run that has not
/// decided to replace anything yet. It has the download's transport rules and
/// none of its records, and it leaves nothing behind unless it succeeds.
@Suite("Podcast original staging")
struct PodcastDownloadCoordinatorStagingTests {
    private typealias Fixture = PodcastPreparationPipelineTests.Fixture

    private func coordinator(
        _ fixture: Fixture, events: [PodcastDownloadEvent], duration: Double = 12
    ) -> PodcastDownloadCoordinator {
        PodcastDownloadCoordinator(
            store: fixture.store, libraryDirectory: fixture.libraryDirectory,
            transport: StagingTransport(events: events), mediaValidator: StagingValidator(duration: duration))
    }

    private func response(_ fixture: Fixture, status: Int = 200, mediaType: String = "audio/mpeg",
                          length: Int64? = nil, url: URL? = nil) -> PodcastDownloadEvent {
        .response(.init(url: url ?? fixture.enclosureURL, statusCode: status, mediaType: mediaType,
                        expectedByteCount: length))
    }

    private func stagedFiles(_ fixture: Fixture) -> [String] {
        let directory = fixture.libraryDirectory.appendingPathComponent(".podcast-staging")
        return (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    }

    @Test func stagesAndHashesTheOriginalWithoutTouchingTheLibrary() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let before = try await fixture.store.download(for: fixture.episodeID)
        let revisionsBefore = try await fixture.store.revisions(for: fixture.episodeID)
        let body = Data("a different original".utf8)
        let progress = StagingProgressLog()
        let staged = try await coordinator(fixture, events: [
            response(fixture, length: Int64(body.count)),
            .data(body.prefix(8)), .data(body.dropFirst(8)),
        ]).stageOriginal(episodeID: fixture.episodeID, enclosureURL: fixture.enclosureURL,
                         onStatus: { progress.append($0) })

        #expect(staged.contentHash == Fixture.contentHash(body))
        #expect(staged.byteCount == Int64(body.count))
        #expect(staged.durationSeconds == 12)
        #expect(try Data(contentsOf: staged.url) == body)
        #expect(staged.url.deletingLastPathComponent().lastPathComponent == ".podcast-staging")
        #expect(fixture.store.inFlightMedia.isInFlight(staged.url), "a sweep may not reclaim it mid-run")

        // Neither the ready revision nor its download record moved.
        #expect(try await fixture.store.download(for: fixture.episodeID) == before)
        #expect(try await fixture.store.revisions(for: fixture.episodeID) == revisionsBefore)

        let values = progress.values
        #expect(values.first?.stage == .transferring)
        #expect(values.last?.stage == .completed)
        let received = values.filter { $0.stage == .transferring }.map(\.bytesReceived)
        #expect(received == received.sorted() && received.last == Int64(body.count),
                "live progress reaches the whole file")

        staged.discard(in: fixture.store)
        #expect(stagedFiles(fixture).isEmpty)
        #expect(!fixture.store.inFlightMedia.isInFlight(staged.url))
        staged.discard(in: fixture.store)
    }

    @Test func aRefusedTransferLeavesNoStagingFile() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let refusals: [(PodcastDownloadCoordinatorError, [PodcastDownloadEvent])] = [
            (.invalidResponse(503), [response(fixture, status: 503)]),
            (.invalidURL, [response(fixture, url: URL(string: "http://cdn.example.test/e1.mp3"))]),
            (.mediaTypeMismatch(expected: "audio/mpeg", actual: "audio/ogg"),
             [response(fixture, mediaType: "audio/ogg")]),
            (.declaredSizeMismatch(expected: 7, actual: 3), [response(fixture, length: 7), .data(Data("abc".utf8))]),
            (.invalidAudio, [response(fixture)]),
        ]
        for (expected, events) in refusals {
            await #expect(throws: expected) {
                _ = try await coordinator(fixture, events: events)
                    .stageOriginal(episodeID: fixture.episodeID, enclosureURL: fixture.enclosureURL)
            }
            #expect(stagedFiles(fixture).isEmpty, "after \(expected)")
        }
    }

    @Test func anInsecureEnclosureIsRefusedBeforeAnyTransfer() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let insecure = try #require(URL(string: "http://cdn.example.test/e1.mp3"))
        await #expect(throws: PodcastDownloadCoordinatorError.invalidURL) {
            _ = try await coordinator(fixture, events: [response(fixture), .data(Data("abc".utf8))])
                .stageOriginal(episodeID: fixture.episodeID, enclosureURL: insecure)
        }
        #expect(stagedFiles(fixture).isEmpty)
    }

    @Test func aStoppedTransferIsCancelledAndLeavesNoStagingFile() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let transport = HangingTransport(first: response(fixture))
        let coordinator = PodcastDownloadCoordinator(
            store: fixture.store, libraryDirectory: fixture.libraryDirectory,
            transport: transport, mediaValidator: StagingValidator(duration: 12))
        let task = Task {
            try await coordinator.stageOriginal(episodeID: fixture.episodeID, enclosureURL: fixture.enclosureURL)
        }
        await transport.started.wait()
        task.cancel()
        await #expect(throws: PodcastDownloadCoordinatorError.cancelled) { _ = try await task.value }
        #expect(stagedFiles(fixture).isEmpty)
        #expect(try await fixture.store.download(for: fixture.episodeID)?.status == .completed,
                "the download record is not the transfer's to change")
    }
}

private extension PodcastPreparationPipelineTests.Fixture {
    /// The enclosure the fixture's episode was saved with.
    var enclosureURL: URL { URL(string: "https://cdn.example.test/e1.mp3")! }
}

private final class StagingProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [PodcastDownloadProgress] = []
    var values: [PodcastDownloadProgress] { lock.withLock { storage } }
    func append(_ value: PodcastDownloadProgress) { lock.withLock { storage.append(value) } }
}

private struct StagingTransport: PodcastDownloadTransporting {
    let events: [PodcastDownloadEvent]
    func events(for url: URL) -> AsyncThrowingStream<PodcastDownloadEvent, Error> {
        AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

private struct StagingValidator: PodcastMediaValidating {
    let duration: Double
    func duration(of url: URL, onStatus: @escaping @Sendable (String) -> Void) async throws -> Double { duration }
}

/// Answers, then waits for the listener to stop it.
private struct HangingTransport: PodcastDownloadTransporting {
    let first: PodcastDownloadEvent
    let started = StartedFlag()

    func events(for url: URL) -> AsyncThrowingStream<PodcastDownloadEvent, Error> {
        let flag = started
        let event = first
        return AsyncThrowingStream { continuation in
            continuation.yield(event)
            Task { await flag.open() }
            // Never finishes: only the consumer's cancellation ends the loop.
        }
    }
}

private actor StartedFlag {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func open() { isOpen = true; waiters.forEach { $0.resume() }; waiters = [] }
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
