import Darwin
import Foundation
import Testing
@testable import WiltedProducer

@Suite("Podcast subprocess pipe EOF", .serialized)
struct PodcastPipeEOFTests {
    @Test func eofHandlersStopReadingAfterTheWorkerClosesOutput() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = directory.appendingPathComponent("closed-output-worker.sh")
        try """
        #!/bin/sh
        cat >/dev/null
        exec 1>&-
        exec 2>&-
        : > "$(dirname "$0")/worker-ready"
        sleep 2
        """.write(to: worker, atomically: true, encoding: .utf8)

        let runner = SubprocessPodcastPipelineRunner(configuration: .init(
            interpreterURL: URL(fileURLWithPath: "/bin/sh"), workerURL: worker, timeout: 4
        ))
        let startedAt = Date()
        let run = Task {
            try await runner.run(request: Data("{}".utf8)) { _ in }
        }

        do {
            try await waitForFile(directory.appendingPathComponent("worker-ready"))
            let cpuBefore = cpuSeconds()
            try await Task.sleep(for: .seconds(1.2))
            let cpuElapsed = cpuSeconds() - cpuBefore
            #expect(cpuElapsed < 0.7)

            do {
                _ = try await run.value
                Issue.record("worker with closed output should report no-output")
            } catch let error as PodcastPreparationError {
                guard case .workerFailed(let code, _) = error else {
                    Issue.record("expected no-output, got \(error)")
                    return
                }
                #expect(code == "no-output")
            }
            #expect(Date().timeIntervalSince(startedAt) < 3.5)
        } catch {
            run.cancel()
            _ = try? await run.value
            throw error
        }
    }

    private func temporaryDirectory() throws -> URL {
        guard let tmpdir = ProcessInfo.processInfo.environment["TMPDIR"], !tmpdir.isEmpty else {
            throw CocoaError(.fileNoSuchFile)
        }
        let directory = URL(fileURLWithPath: tmpdir, isDirectory: true)
            .appendingPathComponent("wilted-pipe-eof-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    private func seconds(_ value: timeval) -> Double {
        Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000
    }

    private func waitForFile(_ file: URL) async throws {
        let deadline = Date().addingTimeInterval(1)
        while !FileManager.default.fileExists(atPath: file.path) {
            guard Date() < deadline else { throw CocoaError(.fileReadNoSuchFile) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
