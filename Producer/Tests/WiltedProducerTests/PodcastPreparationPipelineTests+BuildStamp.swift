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

    @Test func checkoutRevisionScopesDirtyStateAndDetectsCleanAndDirtyRevisions() async throws {
        let repoRoot = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: repoRoot) }

        let workerDir = repoRoot.appendingPathComponent("Workers", isDirectory: true)
        let runtimeDir = repoRoot.appendingPathComponent("Runtime", isDirectory: true)
        let outsideDir = repoRoot.appendingPathComponent("Outside", isDirectory: true)
        for dir in [workerDir, runtimeDir, outsideDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let workerFile = workerDir.appendingPathComponent("wilted_pipeline.py")
        let runtimeFile = runtimeDir.appendingPathComponent("ads.py")
        let outsideFile = outsideDir.appendingPathComponent("other.txt")
        try Data("worker".utf8).write(to: workerFile)
        try Data("runtime".utf8).write(to: runtimeFile)
        try Data("outside".utf8).write(to: outsideFile)

        try runTestGit(["init"], in: repoRoot)
        try runTestGit(["add", "."], in: repoRoot)
        try runTestGit([
            "-c", "user.name=Test Runner",
            "-c", "user.email=test@example.com",
            "commit", "-m", "Initial commit",
        ], in: repoRoot)

        let scopedDirs = [workerDir, runtimeDir]

        // 1. Clean prints 10 hex characters
        let cleanRev = try #require(await PodcastPreparationBuildStamp.checkoutRevision(of: scopedDirs))
        #expect(cleanRev.count == 10)
        #expect(cleanRev.allSatisfy { $0.isHexDigit })

        // 2. An untracked file stays clean
        let untracked = workerDir.appendingPathComponent("untracked.py")
        try Data("untracked".utf8).write(to: untracked)
        #expect(await PodcastPreparationBuildStamp.checkoutRevision(of: scopedDirs) == cleanRev)

        // 3. A modified tracked file outside the scoped directories stays clean
        try Data("outside modified".utf8).write(to: outsideFile)
        #expect(await PodcastPreparationBuildStamp.checkoutRevision(of: scopedDirs) == cleanRev)

        // 4. A modified tracked file under the scoped directory prints <same 10 hex>-dirty
        try Data("worker modified".utf8).write(to: workerFile)
        #expect(await PodcastPreparationBuildStamp.checkoutRevision(of: scopedDirs) == "\(cleanRev)-dirty")

        // 5. A plain non-git directory returns nil
        let nonGit = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: nonGit) }
        #expect(await PodcastPreparationBuildStamp.checkoutRevision(of: [nonGit]) == nil)
    }

    @Test func prepareWithStubCodeRevisionRecordsBuildStampAndEvidence() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        let stubRevision = "abc1234567-dirty"
        let stub = Fixture.cuttingStub(codeRevision: stubRevision)
        let pipeline = fixture.pipeline(stub)
        _ = try await pipeline.prepare(episodeID: fixture.episodeID)

        let requestID = PodcastPreparationPipeline.requestID(for: fixture.episodeID)
        let run = try #require(try await fixture.store.preparationRuns().first { $0.requestID == requestID })
        #expect(run.buildStamp?.codeRevision == stubRevision)

        let terminalEntry = try #require(run.entries.last { $0.status.terminal })
        let terminalEvidence = try #require(terminalEntry.status.evidence)
        #expect(terminalEvidence.fields["codeRevision"] == stubRevision)
    }

    @Test func prepareWithDefaultRunnerOmitsCodeRevisionInEvidence() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        let pipeline = fixture.pipeline(Fixture.cuttingStub())
        _ = try await pipeline.prepare(episodeID: fixture.episodeID)

        let requestID = PodcastPreparationPipeline.requestID(for: fixture.episodeID)
        let run = try #require(try await fixture.store.preparationRuns().first { $0.requestID == requestID })
        #expect(run.buildStamp?.codeRevision == nil)

        let evidenceEntries = run.entries.compactMap(\.status.evidence)
        #expect(!evidenceEntries.isEmpty)
        for evidence in evidenceEntries {
            #expect(evidence.fields["codeRevision"] == nil)
        }
    }
}

private func runTestGit(_ arguments: [String], in directory: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = directory
    var environment = ProcessInfo.processInfo.environment
    environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
    environment["GIT_CONFIG_NOSYSTEM"] = "1"
    environment["GIT_OPTIONAL_LOCKS"] = "0"
    process.environment = environment
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "test.git", code: Int(process.terminationStatus))
    }
}
