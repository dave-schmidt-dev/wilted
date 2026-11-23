import Darwin
import Foundation
import Testing
@testable import WiltedProducer

/// The preparation worker, and every tool it starts, runs at a background priority unless the
/// listener turns that off, so a long transcription does not slow the rest of the Mac.
@Suite("Podcast worker priority", .serialized)
struct PodcastWorkerPriorityTests {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int32] = []
        func record(_ value: Int32) { lock.withLock { values.append(value) } }
        var recorded: [Int32] { lock.withLock { values } }
    }

    /// Runs a worker that records its own nice value and a child's, then exits without a result.
    private func run(_ priority: WorkerPriority, calls: Calls? = nil) async throws -> (worker: Int32, child: Int32) {
        let directory = OwnedTestTemp.root.appendingPathComponent("worker-priority-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = directory.appendingPathComponent("priority-worker.sh")
        try """
        #!/bin/sh
        cat >/dev/null
        sleep 0.3
        dir="$(dirname "$0")"
        ps -o nice= -p $$ > "$dir/worker-nice"
        sh -c 'ps -o nice= -p $$' > "$dir/child-nice"
        exit 3
        """.write(to: worker, atomically: true, encoding: .utf8)
        var configuration = SubprocessPodcastPipelineRunner.Configuration(
            interpreterURL: URL(fileURLWithPath: "/bin/sh"), workerURL: worker, timeout: 30, priority: priority
        )
        if let calls {
            let real = configuration.lowerPriority
            configuration.lowerPriority = { pid, nice in calls.record(nice); real(pid, nice) }
        }
        let runner = SubprocessPodcastPipelineRunner(configuration: configuration, retrySleep: { _ in })
        _ = try? await runner.run(request: Data("{}".utf8)) { _ in }
        func nice(_ name: String) throws -> Int32 {
            let text = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            return try #require(Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return (try nice("worker-nice"), try nice("child-nice"))
    }

    private var ownNice: Int32 {
        errno = 0
        return getpriority(PRIO_PROCESS, 0)
    }

    @Test func aLowPriorityWorkerAndTheToolsItStartsRunBelowTheApp() async throws {
        let calls = Calls()
        let seen = try await run(.low, calls: calls)
        // The runner relaunches a worker that exits before answering, so each launch is lowered.
        #expect(!calls.recorded.isEmpty && calls.recorded.allSatisfy { $0 == WorkerPriority.lowNiceValue },
                "every launch is lowered to the low value")
        // A process can only lower its priority, so the floor is whichever is lower already.
        let expected = max(ownNice, WorkerPriority.lowNiceValue)
        #expect(seen.worker == expected)
        #expect(seen.child == expected, "a tool the worker starts inherits the low priority")
    }

    @Test func aNormalPriorityWorkerKeepsTheAppsPriority() async throws {
        let calls = Calls()
        let seen = try await run(.normal, calls: calls)
        #expect(calls.recorded.isEmpty)
        #expect(seen.worker == ownNice)
        #expect(seen.child == ownNice)
    }

    @Test func theSettingIsOnUntilTheListenerTurnsItOff() throws {
        let suite = "wilted-worker-priority-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(WorkerPriority.userSetting.isLow(defaults: defaults), "on by default")
        defaults.set(false, forKey: WorkerPriority.userSettingKey)
        #expect(!WorkerPriority.userSetting.isLow(defaults: defaults))
        defaults.set(true, forKey: WorkerPriority.userSettingKey)
        #expect(WorkerPriority.userSetting.isLow(defaults: defaults))
        #expect(WorkerPriority.low.isLow(defaults: defaults) && !WorkerPriority.normal.isLow(defaults: defaults))
    }
}
