import Foundation
import Testing
import WiltedDomain
@testable import WiltedProducer

@Suite struct PodcastWorkerStartupRetryTests {
    @Test func retriesStartupCrashAndCompletesPreparation() async throws {
        try await checkWorker("""
        [ "$(wc -c < "$0.launches")" -gt 1 ] || exit 1
        cat >/dev/null
        cat "$0.response"
        """, launches: 2, succeeds: true)
    }

    @Test func failsPreparationAfterThreeStartupCrashes() async throws {
        try await checkWorker("exit 1", launches: 3, succeeds: false)
    }

    @Test func failsWithoutRetryAfterWorkerProgress() async throws {
        try await checkWorker("""
        printf '{"stage":"working"}' >&2
        exit 1
        """, launches: 1, succeeds: false)
    }

    private func checkWorker(_ script: String, launches: Int, succeeds: Bool) async throws {
        let fixture = try await PodcastPreparationPipelineTests.Fixture()
        defer { fixture.remove() }
        let worker = fixture.root.appendingPathComponent("worker.sh")
        try ("printf x >> \"$0.launches\"\n" + script).write(to: worker, atomically: true, encoding: .utf8)
        let response = try JSONSerialization.data(withJSONObject: [
            "ok": true, "protocolVersion": 2, "timing": "none",
            "audioPath": fixture.audioURL.path, "audioChanged": false,
            "report": ["outcome": "disabled", "rawNominations": [[String: Any]]()] as [String: Any]
        ])
        try response.write(to: worker.appendingPathExtension("response"))

        let runner = SubprocessPodcastPipelineRunner(configuration: .init(
            interpreterURL: URL(fileURLWithPath: "/bin/sh"), workerURL: worker
        ), retrySleep: { _ in })
        let pipeline = fixture.pipeline(runner)
        do {
            _ = try await pipeline.prepare(
                episodeID: fixture.episodeID,
                policy: PodcastPreparationPolicySnapshot(transcriptPolicy: .bestAvailable, removeAds: false)
            )
            #expect(succeeds)
        } catch let PodcastPreparationError.workerFailed(code, _) {
            #expect(!succeeds)
            #expect(code == "no-output")
        }
        let attempts = try Data(contentsOf: worker.appendingPathExtension("launches"))
        #expect(attempts.count == launches)
        let entries = try await fixture.store.preparationJournal(
            for: PodcastPreparationPipeline.requestID(for: fixture.episodeID)
        )
        let terminal = try #require(entries.last { $0.status.terminal })
        #expect(terminal.status.stage == (succeeds ? .completed : .failed))
    }
}
