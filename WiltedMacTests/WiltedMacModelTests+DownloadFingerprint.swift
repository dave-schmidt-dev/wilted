import Foundation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

extension WiltedMacModelTests {
    func testDownloadCheckpointAwaitsInjectedFingerprintAfterBootstrap() async throws {
        let entered = expectation(description: "download resolver entered")
        let released = FingerprintGate()
        defer { Task { await released.open() } }
        let resolver = DownloadCheckpointResolver(value: "download-resolved", gate: released,
                                                   entered: { entered.fulfill() })
        let fixture = try await checkpointDownloadFixture("delayed", resolver: resolver)
        fixture.model.downloadEpisode(fixture.episode)
        await fulfillment(of: [entered], timeout: 5)
        let pending = try await fixture.store.requiresForcedRedownload(for: fixture.id)
        XCTAssertTrue(pending, "the checkpoint cannot commit before resolution")
        XCTAssertFalse(fixture.model.isClosingTemporaryState, "the main actor remains responsive")
        await released.open()
        await fixture.model.waitForPodcastOperations()
        try await assertCheckpointDownload(fixture, fingerprint: "download-resolved")
        let calls = await resolver.calls
        XCTAssertEqual(calls, 2, "bootstrap nil and exactly one download resolution")
        try await fixture.model.close()
    }

    func testDownloadCheckpointExplicitFingerprintPrecedesInjectedResolver() async throws {
        let resolver = DownloadCheckpointResolver(value: "must-not-win")
        let fixture = try await checkpointDownloadFixture("explicit", resolver: resolver,
                                                         explicitFingerprint: "explicit-download")
        fixture.model.downloadEpisode(fixture.episode)
        await fixture.model.waitForPodcastOperations()
        try await assertCheckpointDownload(fixture, fingerprint: "explicit-download")
        let calls = await resolver.calls
        XCTAssertEqual(calls, 1, "explicit fingerprint bypasses download resolution after bootstrap")
        try await fixture.model.close()
    }

    func testDownloadCheckpointNilResolverKeepsForcedMarkerAndVerifiedBytes() async throws {
        let resolver = DownloadCheckpointResolver(value: nil)
        let fixture = try await checkpointDownloadFixture("nil", resolver: resolver)
        fixture.model.downloadEpisode(fixture.episode)
        await fixture.model.waitForPodcastOperations()
        try await assertCheckpointDownload(fixture, fingerprint: nil)
        let message = try XCTUnwrap(fixture.model.podcastOperationMessage)
        XCTAssertTrue(message.contains("recovery checkpoint could not be saved"))
        let calls = await resolver.calls
        XCTAssertEqual(calls, 2)
        try await fixture.model.close()
    }

    private struct CheckpointDownloadFixture {
        let model: WiltedMacModel
        let store: LocalLibraryStore
        let id: ItemID
        let episode: WiltedMacEpisode
        let bytes: Data
    }

    private func checkpointDownloadFixture(
        _ suffix: String, resolver: DownloadCheckpointResolver,
        explicitFingerprint: String? = nil
    ) async throws -> CheckpointDownloadFixture {
        let directory = temporaryDirectory("checkpoint-\(suffix)")
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/checkpoint-\(suffix).xml"))
        let enclosure = try XCTUnwrap(URL(string: "https://media.example.test/checkpoint-\(suffix).mp3"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let id = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: suffix, enclosureURL: enclosure)
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let bytes = Data("verified-checkpoint-\(suffix)".utf8)
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(itemID: feedID, canonicalURL: feedURL,
                                                           title: "Checkpoint", createdAt: created))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await store.save(episode: try PodcastEpisode(
                    itemID: id, feedID: feedID, feedURL: feedURL, rssGUID: suffix,
                    title: "Checkpoint \(suffix)", publishedTime: created, enclosureURL: enclosure,
                    enclosureMediaType: "audio/mpeg", createdAt: created
                ))
                try await store.save(feedAutomationPolicy: FeedAutomationPolicy(
                    autoKeep: .off, autoDownload: .off, autoPrepare: .off
                ), for: feedID)
                return store
            },
            podcastDownloadTransportFactory: {
                StubPodcastDownloadTransport(events: [
                    .response(.init(url: enclosure, statusCode: 200, mediaType: "audio/mpeg",
                                    expectedByteCount: Int64(bytes.count))), .data(bytes)
                ])
            },
            podcastMediaValidatorFactory: { StubPodcastMediaValidator(duration: 12) },
            pipelineFingerprint: explicitFingerprint,
            pipelineFingerprintResolution: { await resolver.resolve() },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        addTeardownBlock { try await model.close() }
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        XCTAssertEqual(model.startupState, .ready)
        let store = try XCTUnwrap(model.store)
        // Install after bootstrap so recovery cannot start the transfer before
        // the test has control of the download-time resolution boundary.
        let requestID = LocalLibraryStore.forcedRedownloadRequestPrefix + id.rawValue
        let error = try ProducerError(code: .invalidRequest, message: "fresh bytes required",
                                      retryable: true, stage: "pipeline-invalidation")
        let evidence = try PreparationEvidence(kind: "podcast-pipeline-invalidation", fields: [
            "fingerprint": "old-checkpoint", "requiresRedownload": "true"
        ])
        let status = try PreparationStatus(
            stage: .failed, detail: error.message, cancellable: false,
            terminalResult: try PreparationTerminalResult(outcome: .failed, error: error),
            emittedAt: created, evidence: evidence
        )
        try await store.record(preparation: PreparationJournalEntry(
            id: requestID + "|marker", itemID: id, requestID: requestID, status: status
        ))
        return CheckpointDownloadFixture(model: model, store: store, id: id,
            episode: try XCTUnwrap(model.episodes.first { $0.id == id.rawValue }), bytes: bytes)
    }

    private func assertCheckpointDownload(_ fixture: CheckpointDownloadFixture,
                                          fingerprint: String?) async throws {
        let download = try await fixture.store.download(for: fixture.id)
        XCTAssertEqual(download?.status, .completed)
        let revisions = try await fixture.store.revisions(for: fixture.id)
        let revision = try XCTUnwrap(revisions.first)
        XCTAssertEqual(try Data(contentsOf: revision.mediaURL), fixture.bytes)
        let forced = try await fixture.store.requiresForcedRedownload(for: fixture.id)
        XCTAssertEqual(forced, fingerprint == nil)
        let journal = try await fixture.store.preparationJournal(
            for: LocalLibraryStore.resetPreparationRequestPrefix + fixture.id.rawValue)
        if let fingerprint {
            XCTAssertEqual(journal.last?.status.evidence?.fields["fingerprint"], fingerprint)
            XCTAssertEqual(journal.last?.status.evidence?.fields["requiresRedownload"], "false")
        } else {
            XCTAssertTrue(journal.isEmpty, "unresolved provenance cannot create a reset marker")
        }
    }

}

/// Separates the bootstrap nil response from the controlled download resolution.
private actor DownloadCheckpointResolver {
    private(set) var calls = 0
    private let value: String?
    private let gate: FingerprintGate?
    private let entered: @Sendable () -> Void

    init(value: String?, gate: FingerprintGate? = nil,
         entered: @escaping @Sendable () -> Void = {}) {
        self.value = value
        self.gate = gate
        self.entered = entered
    }

    func resolve() async -> String? {
        calls += 1
        if calls == 1 { return nil }
        entered()
        await gate?.wait()
        return value
    }
}
