import Foundation
import Testing
import WiltedDomain
@testable import WiltedProducer

/// `podcastEpisodesToPrepareAgain()` offers an episode when its newest attempt
/// did not run on the current engine. Every fixture here is left behind by the
/// real pipeline, with `engineVersion` standing in for an earlier release, so
/// the journal shapes under test are the ones a library really holds.
extension PodcastPreparationPipelineTests {
    static let olderEngine = "podcast-preparation-v11"

    /// The worker's own report for a run that could not resolve an
    /// advertisement. W-INV-013 keeps the whole original, so audio, duration
    /// and removed time say exactly that.
    static func uncertainResponse(audioURL: URL) -> [String: Any] {
        let warning = "original audio includes ads: classifier could not resolve IDs 0"
        var audit: [String: Any] = WorkerStub.cleanAudit()
        audit["unresolvedIds"] = [0]
        audit["incompleteError"] = "classifier could not resolve IDs 0"
        audit["warning"] = warning
        // The uncertain contract requires both diagnostic lists to be present.
        audit["heldSpans"] = [[String: Any]]()
        audit["declinedCommercialEvidenceSeeds"] = [[String: Any]]()
        return [
            "ok": true, "protocolVersion": 2, "timing": "none", "audioPath": audioURL.path,
            "audioChanged": false, "durationSeconds": 12, "removedSeconds": 0.0,
            "adSegments": [[String: Any]](), "keepIntervals": [[String: Any]](),
            "report": ["outcome": "uncertain", "rawNominations": [[String: Any]](),
                       "warning": warning, "audit": audit],
        ]
    }

    @Test func aCutFromAnOlderEngineIsOfferedWithWhatItRemoved() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let cut = try await fixture.pipeline(Fixture.cuttingStub(), engineVersion: Self.olderEngine)
            .prepare(episodeID: fixture.episodeID)

        let candidate = try #require(try await fixture.store.podcastEpisodesToPrepareAgain().first)
        #expect(candidate.episodeID == fixture.episodeID)
        #expect(candidate.readyRevision.revision.revisionID == cut.revision.revisionID)
        #expect(candidate.isCut)
        #expect(candidate.sourceHash == fixture.contentHash)
        #expect(candidate.keptTimeline?.kept.map(\.originalStartSeconds) == [0.0, 7.5])
        #expect(candidate.enclosureURL.absoluteString == "https://cdn.example.test/e1.mp3")
    }

    @Test func anUncertainPreparationOfTheOriginalIsOfferedAsNotCut() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let worker = WorkerStub(response: Self.uncertainResponse(audioURL: fixture.audioURL))
        _ = try await fixture.pipeline(worker, engineVersion: Self.olderEngine).prepare(episodeID: fixture.episodeID)

        let candidate = try #require(try await fixture.store.podcastEpisodesToPrepareAgain().first)
        #expect(!candidate.isCut)
        #expect(candidate.readyRevision.revision.revisionID == fixture.revisionID)
        #expect(candidate.keptTimeline == nil)
        #expect(candidate.sourceHash == nil)

        // The original is only "the existing path" while its file is there.
        try FileManager.default.removeItem(at: fixture.audioURL)
        let withoutFile = try #require(try await fixture.store.podcastEpisodesToPrepareAgain().first)
        #expect(withoutFile.isCut, "with no original on disk the episode has to download it again")
    }

    @Test func aLegacyEngineIsOlderThanTheCurrentOne() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        _ = try await fixture.pipeline(Fixture.cuttingStub(), engineVersion: "unknown-legacy")
            .prepare(episodeID: fixture.episodeID)
        #expect(try await fixture.store.podcastEpisodesToPrepareAgain().map(\.episodeID) == [fixture.episodeID])
    }

    @Test func anEpisodeTheCurrentEngineCutIsNotOffered() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        _ = try await fixture.pipeline(Fixture.cuttingStub()).prepare(episodeID: fixture.episodeID)
        #expect(try await fixture.store.podcastEpisodesToPrepareAgain().isEmpty)
    }

    @Test func anEpisodeTheCurrentEngineCouldNotResolveIsNotOffered() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let worker = WorkerStub(response: Self.uncertainResponse(audioURL: fixture.audioURL))
        let result = try await fixture.pipeline(worker).prepare(episodeID: fixture.episodeID)
        #expect(result.adRemovalOutcome == "uncertain")
        #expect(try await fixture.store.podcastEpisodesToPrepareAgain().isEmpty,
                "running it again would only reach the same answer")
    }

    @Test func aFailedAttemptByTheCurrentEngineCountsAsATry() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        _ = try await fixture.pipeline(Fixture.cuttingStub(), engineVersion: Self.olderEngine)
            .prepare(episodeID: fixture.episodeID)
        #expect(try await fixture.store.podcastEpisodesToPrepareAgain().count == 1)

        await #expect(throws: PodcastPreparationError.self) {
            try await fixture.pipeline(ProbingWorker {}).prepare(episodeID: fixture.episodeID)
        }
        #expect(try await fixture.store.podcastEpisodesToPrepareAgain().isEmpty,
                "the newest attempt failed on the current engine, so its Retry is the next step")
    }

    /// Stopping a run decided nothing, so it cannot stand in for trying.
    @Test func aCancelledAttemptDoesNotCount() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        _ = try await fixture.pipeline(Fixture.cuttingStub(), engineVersion: Self.olderEngine)
            .prepare(episodeID: fixture.episodeID)
        await #expect(throws: (any Error).self) {
            try await fixture.pipeline(CancellingWorker()).prepare(episodeID: fixture.episodeID)
        }
        #expect(try await fixture.store.podcastEpisodesToPrepareAgain().count == 1)
    }

    @Test func aRetiredEpisodeIsNotOffered() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        _ = try await fixture.pipeline(Fixture.cuttingStub(), engineVersion: Self.olderEngine)
            .prepare(episodeID: fixture.episodeID)
        #expect(try await fixture.store.retireEpisode(fixture.episodeID))
        #expect(try await fixture.store.podcastEpisodesToPrepareAgain().isEmpty)
    }

    @Test func aCompletedEpisodeIsNotOffered() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let cut = try await fixture.pipeline(Fixture.cuttingStub(), engineVersion: Self.olderEngine)
            .prepare(episodeID: fixture.episodeID)
        let finished = Timestamp(Date(timeIntervalSince1970: 1_700_000_500))
        try await fixture.store.saveListening(PodcastListeningState(
            episodeID: fixture.episodeID, completedAt: finished,
            lastRevisionID: cut.revision.revisionID, updatedAt: finished))
        #expect(try await fixture.store.podcastEpisodesToPrepareAgain().isEmpty)
    }

    @Test func anInvalidatedOutcomeIsNotOffered() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let cut = try await fixture.pipeline(Fixture.cuttingStub(), engineVersion: Self.olderEngine)
            .prepare(episodeID: fixture.episodeID)
        try await fixture.store.savePreparationOutcome(PodcastPreparationOutcome(
            episodeID: fixture.episodeID, revisionID: cut.revision.revisionID, policyDigest: "digest",
            pipelineFingerprint: nil, semanticVersion: Self.olderEngine,
            producedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_300)),
            eligibility: .invalid, invalidationRuleID: "rule"))
        #expect(try await fixture.store.podcastEpisodesToPrepareAgain().isEmpty)
    }
}

/// A worker whose run is stopped by the listener.
actor CancellingWorker: PodcastPipelineRunning {
    func run(
        request payload: Data,
        onProgress: @escaping @Sendable (PodcastPreparationProgress) -> Void
    ) async throws -> Data {
        throw CancellationError()
    }
}
