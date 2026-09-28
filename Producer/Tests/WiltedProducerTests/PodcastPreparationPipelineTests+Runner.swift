import CryptoKit
import Foundation
import Testing
import WiltedDomain
@testable import WiltedProducer

extension PodcastPreparationPipelineTests {
    // MARK: Transcript construction

    @Test func recordsAnAbsentTranscriptWhenTheWorkerFoundNoWords() throws {
        let transcript = try PodcastPreparationPipeline.transcript(
            from: Self.payload(text: nil), itemID: Self.itemID, revisionID: Self.revisionID,
            updatedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        )
        #expect(transcript.availability == .absent)
        #expect(transcript.timing == TranscriptTiming.none)
    }

    @Test func recordsOversizedRatherThanDiscardingAnEpisode() throws {
        let huge = String(repeating: "a ", count: Transcript.maximumTextUTF8Bytes)
        let transcript = try PodcastPreparationPipeline.transcript(
            from: Self.payload(text: huge), itemID: Self.itemID, revisionID: Self.revisionID,
            updatedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        )
        #expect(transcript.availability == .oversized)
        #expect(transcript.text == nil)
    }

    /// Timing that will not fit costs the timing, never the words.
    @Test func keepsTheWordsWhenTheCuesExceedTheTransportBudget() throws {
        let cues = try (0..<(Transcript.maximumCueCount + 10)).map {
            try TranscriptCue(startSeconds: Double($0), endSeconds: Double($0) + 1, text: "cue \($0)")
        }
        var payload = Self.payload(text: "Words that fit.")
        payload.timing = .aligned
        payload.cues = cues
        let transcript = try PodcastPreparationPipeline.transcript(
            from: payload, itemID: Self.itemID, revisionID: Self.revisionID,
            updatedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        )
        #expect(transcript.availability == .available)
        #expect(transcript.text == "Words that fit.")
        #expect(transcript.timing == TranscriptTiming.none)
        #expect(transcript.cues == nil)
    }

    // MARK: Subprocess runner

    /// Exercises the real process plumbing with a shell script standing in for
    /// the Python worker, so stdin delivery, NDJSON progress, and result
    /// collection are covered by the gate without a virtualenv or a model.
    @Test func subprocessRunnerStreamsProgressAndReturnsTheResult() async throws {
        let directory = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = directory.appendingPathComponent("worker.sh")
        try """
        #!/bin/sh
        printf '{"stage":"one","detail":"first","fraction":0.25}\\n' >&2
        printf 'not json at all\\n' >&2
        printf '{"stage":"two","detail":"second"}\\n' >&2
        request=$(cat)
        printf '{"ok":true,"echo":%s}' "$request"
        """.write(to: worker, atomically: true, encoding: .utf8)

        let runner = SubprocessPodcastPipelineRunner(configuration: .init(
            interpreterURL: URL(fileURLWithPath: "/bin/sh"), workerURL: worker, timeout: 30
        ))
        let statuses = StatusLog()
        let output = try await runner.run(request: Data(#"{"audioPath":"/tmp/a.mp3"}"#.utf8)) { progress in
            statuses.append(progress.stage, detail: progress.detail, fraction: progress.fraction)
        }

        let decoded = try #require(try JSONSerialization.jsonObject(with: output) as? [String: Any])
        #expect(decoded["ok"] as? Bool == true)
        #expect((decoded["echo"] as? [String: Any])?["audioPath"] as? String == "/tmp/a.mp3")
        #expect(statuses.stages == ["one", "two"])
        #expect(statuses.fractions.first == 0.25)
    }

    @Test func subprocessRunnerReportsAWorkerThatProducesNothing() async throws {
        let directory = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = directory.appendingPathComponent("silent.sh")
        try "#!/bin/sh\nexit 3\n".write(to: worker, atomically: true, encoding: .utf8)
        let runner = SubprocessPodcastPipelineRunner(configuration: .init(
            interpreterURL: URL(fileURLWithPath: "/bin/sh"), workerURL: worker, timeout: 30
        ))
        await #expect(throws: PodcastPreparationError.self) {
            _ = try await runner.run(request: Data("{}".utf8)) { _ in }
        }
    }

    @Test func subprocessRunnerRefusesToStartWithoutItsPieces() async throws {
        let directory = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = SubprocessPodcastPipelineRunner(configuration: .init(
            interpreterURL: URL(fileURLWithPath: directory.appendingPathComponent("no-python").path),
            workerURL: directory.appendingPathComponent("worker.py")
        ))
        await #expect(throws: PodcastPreparationError.self) {
            _ = try await missing.run(request: Data("{}".utf8)) { _ in }
        }
    }

    /// Every path is overridable, and the shipped defaults name real things.
    @Test func configurationResolvesFromTheEnvironment() {
        let overridden = SubprocessPodcastPipelineRunner.Configuration.resolved(environment: [
            "WILTED_PIPELINE_PYTHON": "/opt/py", "WILTED_PIPELINE_WORKER": "/opt/w.py",
            "WILTED_PIPELINE_PYTHONPATH": "/opt/src", "WILTED_PIPELINE_TIMEOUT_S": "60",
            "WILTED_PIPELINE_TOOL_PATH": "/opt/tools/bin:/opt/more",
        ])
        #expect(overridden.interpreterURL.path == "/opt/py")
        #expect(overridden.workerURL.path == "/opt/w.py")
        #expect(overridden.pythonPath?.path == "/opt/src")
        #expect(overridden.timeout == 60)
        #expect(overridden.toolSearchPaths == ["/opt/tools/bin", "/opt/more"])

        let defaults = SubprocessPodcastPipelineRunner.Configuration.resolved(environment: [:])
        let activeRuntime = "/Documents/Projects/wilted/Producer/Runtime"
        #expect(defaults.interpreterURL.path.hasSuffix(activeRuntime + "/.venv/bin/python"))
        #expect(defaults.pythonPath?.path.hasSuffix(activeRuntime + "/src") == true)
        #expect(defaults.workerURL.lastPathComponent == "wilted_pipeline.py")
        #expect(!defaults.interpreterURL.path.contains("wilted-old"))
        #expect(defaults.pythonPath?.path.contains("wilted-old") == false)
        #expect(defaults.timeout > 0)
        #expect(defaults.toolSearchPaths.contains("/opt/homebrew/bin"))
    }

    @Test func subprocessRunnerNamesMissingRuntimeSourceBeforeLaunchingPython() async throws {
        let directory = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = directory.appendingPathComponent("worker.py")
        try Data("raise RuntimeError('should not launch')\n".utf8).write(to: worker)
        let missingSource = directory.appendingPathComponent("missing-runtime-src")
        let runner = SubprocessPodcastPipelineRunner(configuration: .init(
            interpreterURL: URL(fileURLWithPath: "/usr/bin/python3"),
            workerURL: worker,
            pythonPath: missingSource
        ))

        do {
            _ = try await runner.run(request: Data("{}".utf8)) { _ in }
            Issue.record("expected the missing runtime source preflight to fail")
        } catch let error as PodcastPreparationError {
            #expect(String(describing: error).contains(missingSource.path))
            #expect(String(describing: error).contains("restore Producer/Runtime/src"))
            #expect(String(describing: error).contains("WILTED_PIPELINE_PYTHONPATH"))
        }
    }

    /// The app is launched from Finder with a PATH that cannot find ffmpeg;
    /// the worker's PATH must, without losing anything the app inherited.
    @Test func workerPATHAppendsToolDirectoriesItDoesNotAlreadyHave() {
        let configuration = SubprocessPodcastPipelineRunner.Configuration(
            interpreterURL: URL(fileURLWithPath: "/bin/sh"), workerURL: URL(fileURLWithPath: "/w.sh"),
            toolSearchPaths: ["/opt/homebrew/bin", "/usr/local/bin"]
        )
        #expect(configuration.workerPATH(inherited: "/usr/bin:/bin") == "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin")
        #expect(configuration.workerPATH(inherited: "/opt/homebrew/bin:/usr/bin") == "/opt/homebrew/bin:/usr/bin:/usr/local/bin")
        #expect(configuration.workerPATH(inherited: nil) == "/opt/homebrew/bin:/usr/local/bin")
        #expect(configuration.workerPATH(inherited: "::/usr/bin:") == "/usr/bin:/opt/homebrew/bin:/usr/local/bin")

        // Nothing inherited and nothing configured is still a usable PATH.
        let bare = SubprocessPodcastPipelineRunner.Configuration(
            interpreterURL: URL(fileURLWithPath: "/bin/sh"), workerURL: URL(fileURLWithPath: "/w.sh"),
            toolSearchPaths: [""]
        )
        #expect(bare.workerPATH(inherited: "") == "/usr/bin:/bin:/usr/sbin:/sbin")
    }

    @Test func subprocessRunnerHandsTheWorkerTheExtendedPATH() async throws {
        let directory = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = directory.appendingPathComponent("path.sh")
        try """
        #!/bin/sh
        cat >/dev/null
        printf '{"ok":true,"path":"%s"}' "$PATH"
        """.write(to: worker, atomically: true, encoding: .utf8)
        let runner = SubprocessPodcastPipelineRunner(configuration: .init(
            interpreterURL: URL(fileURLWithPath: "/bin/sh"), workerURL: worker, timeout: 30,
            toolSearchPaths: [directory.path]
        ))
        let output = try await runner.run(request: Data("{}".utf8)) { _ in }
        let decoded = try #require(try JSONSerialization.jsonObject(with: output) as? [String: Any])
        let path = try #require(decoded["path"] as? String)
        #expect(path.split(separator: ":").map(String.init).contains(directory.path))
        // Everything the app inherited is still there, ahead of the additions.
        if let inherited = ProcessInfo.processInfo.environment["PATH"] {
            #expect(path.hasPrefix(inherited.split(separator: ":", omittingEmptySubsequences: true).joined(separator: ":")))
        }
    }

}
