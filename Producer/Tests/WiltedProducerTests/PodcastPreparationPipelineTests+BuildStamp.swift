import Foundation
import Testing
import WiltedDomain
@testable import WiltedProducer

private struct ThrowingRunner: PodcastPipelineRunning {
    func run(
        request payload: Data,
        onProgress: @escaping @Sendable (PodcastPreparationProgress) -> Void
    ) async throws -> Data {
        throw PodcastPreparationError.workerUnavailable("simulated runner throw")
    }
}

extension PodcastPreparationPipelineTests {
    @Test func hostAppVersionResolvesAppAndSourceCommit() {
        let full: [String: Any] = [
            "CFBundleShortVersionString": "0.7.0",
            "CFBundleVersion": "12",
            "WiltedSourceCommit": "abc1234567",
        ]
        #expect(PodcastPreparationBuildStamp.hostAppVersion(info: full) == "0.7.0 (12, abc1234567)")

        let emptyCommit: [String: Any] = [
            "CFBundleShortVersionString": "0.7.0",
            "CFBundleVersion": "12",
            "WiltedSourceCommit": "",
        ]
        #expect(PodcastPreparationBuildStamp.hostAppVersion(info: emptyCommit) == "0.7.0 (12)")

        let withoutKey: [String: Any] = [
            "CFBundleShortVersionString": "0.7.0",
            "CFBundleVersion": "12",
        ]
        #expect(PodcastPreparationBuildStamp.hostAppVersion(info: withoutKey) == nil)

        #expect(PodcastPreparationBuildStamp.hostAppVersion(info: nil) == nil)

        let missingVersionKeys: [String: Any] = [
            "WiltedSourceCommit": "abc1234567",
        ]
        #expect(PodcastPreparationBuildStamp.hostAppVersion(info: missingVersionKeys) == "? (?, abc1234567)")
    }

    @Test func successfulPreparationRecordsBuildStampAndEvidence() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        let appVersion = "0.7.0 (12, abc1234567)"
        let pipeline = fixture.pipeline(Fixture.cuttingStub(), appVersion: appVersion)
        _ = try await pipeline.prepare(episodeID: fixture.episodeID)

        let requestID = PodcastPreparationPipeline.requestID(for: fixture.episodeID)
        let run = try #require(try await fixture.store.preparationRuns().first { $0.requestID == requestID })
        let expectedStamp = PodcastPreparationBuildStamp(
            appVersion: appVersion,
            engineVersion: PodcastPreparationPipeline.semanticVersion
        )
        #expect(run.buildStamp == expectedStamp)

        let terminalEntry = try #require(run.entries.last { $0.status.terminal })
        let terminalEvidence = try #require(terminalEntry.status.evidence)
        #expect(terminalEvidence.kind == LocalLibraryStore.pipelineProvenanceEvidenceKind)
        #expect(terminalEvidence.fields["engineVersion"] == PodcastPreparationPipeline.semanticVersion)
        #expect(terminalEvidence.fields["appVersion"] == appVersion)
    }

    @Test func throwingRunnerStillYieldsRunCarryingBuildStamp() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        let appVersion = "0.7.0 (12, abc1234567)"
        let throwingRunner = ThrowingRunner()
        let pipeline = fixture.pipeline(throwingRunner, appVersion: appVersion)

        await #expect(throws: PodcastPreparationError.workerUnavailable("simulated runner throw")) {
            _ = try await pipeline.prepare(episodeID: fixture.episodeID)
        }

        let requestID = PodcastPreparationPipeline.requestID(for: fixture.episodeID)
        let run = try #require(try await fixture.store.preparationRuns().first { $0.requestID == requestID })
        let expectedStamp = PodcastPreparationBuildStamp(
            appVersion: appVersion,
            engineVersion: PodcastPreparationPipeline.semanticVersion
        )
        #expect(run.buildStamp == expectedStamp)
        #expect(run.buildStamp?.appVersion == appVersion)
        #expect(run.buildStamp?.engineVersion == PodcastPreparationPipeline.semanticVersion)
    }

    @Test func nilAppVersionRecordsNilInBuildStampAndOmitsAppVersionKeyInEvidence() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        let pipeline = fixture.pipeline(Fixture.cuttingStub(), appVersion: nil)
        _ = try await pipeline.prepare(episodeID: fixture.episodeID)

        let requestID = PodcastPreparationPipeline.requestID(for: fixture.episodeID)
        let run = try #require(try await fixture.store.preparationRuns().first { $0.requestID == requestID })
        let expectedStamp = PodcastPreparationBuildStamp(
            appVersion: nil,
            engineVersion: PodcastPreparationPipeline.semanticVersion
        )
        #expect(run.buildStamp == expectedStamp)
        #expect(run.buildStamp?.appVersion == nil)
        #expect(run.buildStamp?.engineVersion == PodcastPreparationPipeline.semanticVersion)

        let evidenceEntries = run.entries.compactMap(\.status.evidence)
        #expect(!evidenceEntries.isEmpty)
        for evidence in evidenceEntries {
            #expect(evidence.fields["appVersion"] == nil)
        }
    }
}
