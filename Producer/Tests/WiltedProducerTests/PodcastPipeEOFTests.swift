import Darwin
import Foundation
import Testing
@testable import WiltedProducer

@Suite("Podcast subprocess pipe EOF", .serialized)
struct PodcastPipeEOFTests {
    @Test func eofHandlersStopReadingAfterTheWorkerClosesOutput() async throws {
        // The EOF handlers run on arbitrary dispatch queues. RUSAGE_SELF is
        // accurate CPU accounting, but sibling suites would pollute it. Run
        // this one case in an isolated, already-built test process first.
        if ProcessInfo.processInfo.environment["WILTED_EOF_CPU_ISOLATED"] != "1" {
            try await runIsolatedCase()
            return
        }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = directory.appendingPathComponent("closed-output-worker.sh")
        try """
        #!/bin/sh
        cat >/dev/null
        exec 1>&-
        exec 2>&-
        : > "$(dirname "$0")/worker-ready"
        while [ ! -e "$(dirname "$0")/worker-release" ]; do sleep 0.1; done
        """.write(to: worker, atomically: true, encoding: .utf8)

        let runner = SubprocessPodcastPipelineRunner(configuration: .init(
            interpreterURL: URL(fileURLWithPath: "/bin/sh"), workerURL: worker, timeout: 60
        ))
        let run = Task {
            try await runner.run(request: Data("{}".utf8)) { _ in }
        }

        do {
            try await waitForFile(directory.appendingPathComponent("worker-ready"))
            let cpuBefore = cpuSeconds()
            try await Task.sleep(for: .seconds(1.2))
            let cpuElapsed = cpuSeconds() - cpuBefore
            #expect(cpuElapsed < 0.7)
            try Data().write(to: directory.appendingPathComponent("worker-release"))

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
        } catch {
            run.cancel()
            _ = try? await run.value
            throw error
        }
    }

    @Test func cancellationWaitsForTermIgnoringWorkerAndBlockedWriter() async throws {
        try await assertStoppedWorker(cancel: true)
    }

    @Test func timeoutWaitsForTermIgnoringWorkerAndBlockedWriter() async throws {
        try await assertStoppedWorker(cancel: false)
    }

    @Test func successfulExitReapsWorkerAndUnblocksLargeStdinWriter() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = directory.appendingPathComponent("exit-without-reading.py")
        try """
        import os, sys, time
        root = os.path.dirname(__file__)
        with open(os.path.join(root, "worker-pid"), "w") as output:
            output.write(str(os.getpid()))
        while not os.path.exists(os.path.join(root, "worker-release")):
            time.sleep(0.01)
        sys.stdout.write('{"ok":true}')
        """.write(to: worker, atomically: true, encoding: .utf8)
        let runner = SubprocessPodcastPipelineRunner(configuration: .init(
            interpreterURL: URL(fileURLWithPath: "/usr/bin/python3"), workerURL: worker, timeout: 5
        ))
        let run = Task {
            try await runner.run(request: Data(repeating: 65, count: 4_000_000)) { _ in }
        }
        let pidFile = directory.appendingPathComponent("worker-pid")
        do {
            try await waitForFile(pidFile)
        } catch {
            run.cancel()
            _ = try? await run.value
            throw error
        }
        let pid = try #require(Int32(try String(contentsOf: pidFile, encoding: .utf8)))
        defer {
            // Only this fixture's exact PID, including a surviving child.
            if kill(pid, 0) == 0 { _ = kill(pid, SIGKILL) }
            let deadline = Date().addingTimeInterval(5)
            while kill(pid, 0) == 0 && Date() < deadline { usleep(10_000) }
        }
        #expect(kill(pid, 0) == 0)
        // Let the 4 MB request fill the stdin pipe while the worker waits.
        try await Task.sleep(for: .milliseconds(250))
        try Data().write(to: directory.appendingPathComponent("worker-release"))

        let result = try await run.value
        #expect(result == Data(#"{"ok":true}"#.utf8))
        let existence = kill(pid, 0)
        let existenceError = errno
        #expect(existence == -1, "runner returned while its completed worker remained live or unreaped")
        #expect(existenceError == ESRCH)
    }

    @Test func workerProgressPreservesSummaryRequestIDAndLegacyDefault() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let requestID = UUID(uuidString: "13AB8FC1-736F-4D64-B630-CC878BD8F1DB")!
        let worker = directory.appendingPathComponent("progress-worker.sh")
        try """
        cat >/dev/null
        printf '%s\n' '{"stage":"summary.generate","requestID":"\(requestID.uuidString)","fraction":0.5}' >&2
        printf '%s' '{"stage":"prep.legacy"}' >&2
        printf '%s' '{"ok":true}'
        """.write(to: worker, atomically: true, encoding: .utf8)
        let recorder = PipeProgressRecorder()
        let runner = SubprocessPodcastPipelineRunner(configuration: .init(
            interpreterURL: URL(fileURLWithPath: "/bin/sh"), workerURL: worker, timeout: 20
        ))
        _ = try await runner.run(request: Data("{}".utf8)) { recorder.append($0) }
        let events = recorder.values()
        #expect(events.count == 2)
        let correlated = try #require(events.first { $0.stage == "summary.generate" })
        #expect(correlated.fraction == 0.5)
        #expect(correlated.requestID == requestID)
        #expect(events.last?.stage == "prep.legacy")
        #expect(events.last?.requestID == nil)
        #expect(PodcastPreparationProgress(stage: "prep.default").requestID == nil)
    }

    private func assertStoppedWorker(cancel: Bool) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = directory.appendingPathComponent("ignore-term.py")
        try """
        import os, signal, time
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        with open(os.path.join(os.path.dirname(__file__), "worker-pid"), "w") as output:
            output.write(str(os.getpid()))
        while True:
            time.sleep(0.05)
        """.write(to: worker, atomically: true, encoding: .utf8)
        let runner = SubprocessPodcastPipelineRunner(configuration: .init(
            interpreterURL: URL(fileURLWithPath: "/usr/bin/python3"), workerURL: worker,
            timeout: cancel ? 60 : 5
        ))
        // No stdin read: the large request proves the detached writer must
        // quiesce after owned process exit, rather than merely be cancelled.
        let run = Task { try await runner.run(request: Data(repeating: 65, count: 4_000_000)) { _ in } }
        let pidFile = directory.appendingPathComponent("worker-pid")
        do { try await waitForFile(pidFile) } catch {
            run.cancel()
            _ = try? await run.value
            throw error
        }
        let pid = try #require(Int32(try String(contentsOf: pidFile, encoding: .utf8)))
        defer {
            // Only this fixture's exact PID, including RED's surviving child.
            if kill(pid, 0) == 0 { _ = kill(pid, SIGKILL) }
            let deadline = Date().addingTimeInterval(5)
            while kill(pid, 0) == 0 && Date() < deadline { usleep(10_000) }
        }
        #expect(kill(pid, 0) == 0)
        if cancel { run.cancel() }
        do {
            _ = try await run.value
            Issue.record("expected cancellation/timeout")
        } catch let error as PodcastPreparationError {
            #expect(error == (cancel ? .cancelled : .workerTimedOut))
        }
        let existence = kill(pid, 0)
        let existenceError = errno
        #expect(existence == -1, "runner returned while its TERM-ignoring worker PID remained live")
        #expect(existenceError == ESRCH)
    }

    private func runIsolatedCase() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("isolated-case.log")
        _ = FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        // Resolve the bundle that supplied this exact test class. This works
        // both under SwiftPM and xctest, without reacquiring SwiftPM's cache lock
        // or finding another cache that could contain older test bytes.
        let bundle = Bundle(for: EOFTestBundleAnchor.self)
        guard bundle.bundleURL.pathExtension == "xctest", bundle.executableURL != nil else {
            Issue.record("EOF CPU regression could not resolve its currently loaded test bundle")
            return
        }
        let environment = ProcessInfo.processInfo.environment
        // Gate sources are staged separately from scripts, so the gate supplies
        // its actual helper. Ordinary SwiftPM runs resolve the source checkout.
        let checkout = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let supervisor = environment["WILTED_EOF_BOUNDED_RUNNER"]
            ?? checkout.appendingPathComponent("scripts/run-bounded.py").path
        guard FileManager.default.fileExists(atPath: supervisor) else {
            Issue.record("EOF CPU regression could not resolve its descendant supervisor")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        let selector = "\(String(reflecting: Self.self))/eofHandlersStopReadingAfterTheWorkerClosesOutput()"
        process.arguments = ["python3", supervisor, "--timeout-seconds", "180", "--",
                             "/usr/bin/xcrun", "xctest", "-XCTest", selector, bundle.bundleURL.path]
        // xctest can dump its environment after a launch/configuration error.
        // Supply only runtime paths and our isolation marker, never credentials.
        var childEnvironment = ["WILTED_EOF_CPU_ISOLATED": "1"]
        for key in ["PATH", "HOME", "TMPDIR", "DEVELOPER_DIR"] {
            childEnvironment[key] = environment[key]
        }
        process.environment = childEnvironment
        process.standardOutput = output
        process.standardError = output
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
                let reapDeadline = Date().addingTimeInterval(120)
                var lastCleanupProgress = Date.distantPast
                while process.isRunning && Date() < reapDeadline {
                    if Date().timeIntervalSince(lastCleanupProgress) >= 15 {
                        print("podcast.eof.cpu-isolation cleanup-running")
                        lastCleanupProgress = Date()
                    }
                    usleep(50_000)
                }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            // Reap after descendant supervision and its watchdog finish,
            // before closing output or removing its temporary root.
            process.waitUntilExit()
        }
        let deadline = Date().addingTimeInterval(300)
        var lastProgress = Date.distantPast
        while process.isRunning {
            try Task.checkCancellation()
            guard Date() < deadline else {
                Issue.record("isolated EOF CPU case did not finish within its execution budget")
                return
            }
            if Date().timeIntervalSince(lastProgress) >= 15 {
                print("podcast.eof.cpu-isolation running")
                lastProgress = Date()
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let result = try String(contentsOf: log, encoding: .utf8)
        #expect(process.terminationStatus == 0, "isolated EOF case failed with status \(process.terminationStatus)")
        // A stale cache or unmatched filter must never pass as zero tests.
        #expect(result.contains("Test eofHandlersStopReadingAfterTheWorkerClosesOutput() passed"))
        #expect(result.range(of: #"Test run with 1 test(?: in [0-9]+ suites?)? passed"#,
                             options: .regularExpression) != nil)
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
        let deadline = Date().addingTimeInterval(20)
        while !FileManager.default.fileExists(atPath: file.path) {
            guard Date() < deadline else { throw CocoaError(.fileReadNoSuchFile) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// Anchors resolution to the loaded test image, including ordinary SwiftPM runs.
private final class EOFTestBundleAnchor: NSObject {}

private final class PipeProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var progress: [PodcastPreparationProgress] = []

    func append(_ value: PodcastPreparationProgress) {
        lock.lock(); defer { lock.unlock() }
        progress.append(value)
    }

    func values() -> [PodcastPreparationProgress] {
        lock.lock(); defer { lock.unlock() }
        return progress
    }
}
