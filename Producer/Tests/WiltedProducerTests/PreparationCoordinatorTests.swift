import Foundation
import Testing
import WiltedDomain
@testable import WiltedProducer

@Suite("Preparation coordinator")
struct PreparationCoordinatorTests {
    @Test func invalidURLProducesOneActionableTerminalFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "wilted-coordinator-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalLibraryStore(url: directory.appending(path: "library.sqlite"))
        let coordinator = PreparationCoordinator(store: store, mediaDirectory: directory.appending(path: "media"))
        let run = await coordinator.start(url: URL(string: "http://example.test/article")!)
        var statuses: [PreparationStatus] = []
        for await status in run.statuses { statuses.append(status) }
        #expect(statuses.map(\.stage) == [.preparing, .failed])
        #expect(statuses.filter(\.terminal).count == 1)
        #expect(statuses.last?.terminalResult?.error?.code == .invalidRequest)
        #expect(statuses.last?.cancellable == false)
    }

    @Test func assemblyCancellationIsTerminalCancelledAndRemovesCandidate() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let prior = fixture.mediaDirectory.appending(path: "prior.m4a")
        try Data("prior".utf8).write(to: prior)
        let (entered, signal) = AsyncStream<Void>.makeStream()
        let (release, releaseSignal) = AsyncStream<Void>.makeStream()
        let coordinator = fixture.coordinator(assembly: { _, _, destination, _ in
            try Data("candidate".utf8).write(to: destination)
            signal.yield()
            for await _ in release { break }
            throw AudioAssemblerError.cancelled
        })

        let run = await coordinator.start(url: fixture.articleURL)
        let statusesTask = Task { await collect(run.statuses) }
        var enteredIterator = entered.makeAsyncIterator()
        await enteredIterator.next()
        await run.cancel()
        releaseSignal.yield(())
        let statuses = await statusesTask.value

        #expect(statuses.last?.stage == .cancelled)
        #expect(statuses.filter(\.terminal).count == 1)
        #expect(try Data(contentsOf: prior) == Data("prior".utf8))
        #expect(try fixture.candidateFiles().isEmpty)
    }

    @Test func saveFailureRemovesPublishedCandidateWithoutTouchingPriorMedia() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let prior = fixture.mediaDirectory.appending(path: "prior.m4a")
        try Data("prior".utf8).write(to: prior)
        let coordinator = fixture.coordinator(
            assembly: { _, itemID, destination, _ in
                try Data("candidate".utf8).write(to: destination)
                return try assemblyResult(itemID: itemID, mediaURL: destination)
            },
            save: { _, _ in throw TestPreparationError.saveFailed }
        )

        let run = await coordinator.start(url: fixture.articleURL)
        let statuses = await collect(run.statuses)

        #expect(statuses.last?.stage == .failed)
        #expect(statuses.filter(\.terminal).count == 1)
        #expect(try Data(contentsOf: prior) == Data("prior".utf8))
        #expect(try fixture.candidateFiles().isEmpty)
    }

    @Test func extractedTextSurvivesSynthesisAndIsPersistedWithTheReadyRevision() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator(assembly: { _, itemID, destination, _ in
            try Data("candidate".utf8).write(to: destination)
            return try assemblyResult(itemID: itemID, mediaURL: destination)
        })

        let statuses = await collect((await coordinator.start(url: fixture.articleURL)).statuses)
        #expect(statuses.last?.stage == .completed)
        let itemID = try ItemID.derive(from: fixture.articleURL)
        let transcript = try await fixture.store.transcript(for: itemID, revisionID: RevisionID(rawValue: "rev-test"))
        #expect(transcript?.availability == .available)
        #expect(transcript?.text == "Fixture article body.")
    }

    @Test func oversized_transcript_preserves_ready_audio() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let body = String(repeating: "x", count: Transcript.maximumTextUTF8Bytes + 1)
        let coordinator = fixture.coordinator(body: body, assembly: { _, itemID, destination, _ in
            try Data("candidate".utf8).write(to: destination)
            return try assemblyResult(itemID: itemID, mediaURL: destination)
        })

        let statuses = await collect((await coordinator.start(url: fixture.articleURL)).statuses)
        let itemID = try ItemID.derive(from: fixture.articleURL)
        let revisionID = try RevisionID(rawValue: "rev-test")
        let storedRevision = try await fixture.store.readyRevision(for: itemID, revisionID: revisionID)
        let transcript = try await fixture.store.transcript(for: itemID, revisionID: revisionID)

        #expect(statuses.last?.stage == .completed)
        #expect(storedRevision?.revision.readiness == .ready)
        #expect(storedRevision?.mediaURL.lastPathComponent.hasPrefix("candidate-") == true)
        #expect(transcript?.availability == .oversized)
        #expect(transcript?.text == nil)
    }

    @Test func olderCompletionCannotRelinquishNewerRunCancellationOwnership() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let (entered, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(2))
        let coordinator = fixture.coordinator(assembly: { _, _, destination, _ in
            try Data("candidate".utf8).write(to: destination)
            signal.yield()
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                throw TestPreparationError.timedOut
            } catch is CancellationError {
                throw AudioAssemblerError.cancelled
            }
        })
        var enteredIterator = entered.makeAsyncIterator()

        let first = await coordinator.start(url: URL(string: "https://example.test/first")!)
        let firstStatusesTask = Task { await collect(first.statuses) }
        await enteredIterator.next()
        let second = await coordinator.start(url: URL(string: "https://example.test/second")!)
        let secondStatusesTask = Task { await collect(second.statuses) }
        let firstStatuses = await firstStatusesTask.value
        await enteredIterator.next()

        await coordinator.cancel()
        let secondStatuses = await secondStatusesTask.value

        #expect(firstStatuses.last?.stage == .cancelled)
        #expect(secondStatuses.last?.stage == .cancelled)
        #expect(try fixture.candidateFiles().isEmpty)
    }
}

private enum TestPreparationError: Error { case saveFailed, timedOut }

private struct CoordinatorFixture {
    let directory: URL
    let mediaDirectory: URL
    let store: LocalLibraryStore
    let articleURL = URL(string: "https://example.test/article")!

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "wilted-coordinator-\(UUID().uuidString)")
        mediaDirectory = directory.appending(path: "media")
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        store = try LocalLibraryStore(url: directory.appending(path: "library.sqlite"))
    }

    func coordinator(
        body: String = "Fixture article body.",
        assembly: @escaping PreparationCoordinator.AssemblyOperation,
        save: PreparationCoordinator.SaveOperation? = nil
    ) -> PreparationCoordinator {
        PreparationCoordinator(
            store: store,
            mediaDirectory: mediaDirectory,
            extraction: { url in
                ExtractedArticle(
                    sourceURL: url, canonicalURL: url, title: "Fixture", source: "example.test",
                    author: nil, body: body
                )
            },
            synthesis: { _ in SpeechSynthesisResult(requestID: "fixture", samples: [0, 0.1, -0.1], sampleRate: 24_000) },
            assembly: assembly,
            save: save
        )
    }

    func candidateFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: mediaDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("candidate-") }
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private func assemblyResult(itemID: ItemID, mediaURL: URL) throws -> AudioAssemblyResult {
    let revision = try AudioRevision(
        itemID: itemID,
        revisionID: RevisionID(rawValue: "rev-test"),
        durationSeconds: 1,
        byteCount: 9,
        contentHash: "sha256:" + String(repeating: "a", count: 64),
        mediaType: "audio/mp4",
        createdAt: Timestamp(Date(timeIntervalSince1970: 1)),
        schemaVersion: 1
    )
    return AudioAssemblyResult(revision: revision, mediaURL: mediaURL)
}

private func collect(_ stream: AsyncStream<PreparationStatus>) async -> [PreparationStatus] {
    var statuses: [PreparationStatus] = []
    for await status in stream { statuses.append(status) }
    return statuses
}
