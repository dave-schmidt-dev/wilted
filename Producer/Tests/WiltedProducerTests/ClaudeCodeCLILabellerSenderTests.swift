import Foundation
import Testing
@testable import WiltedProducer

/// The Claude Code command-line sender, driven through fake `/bin/sh` executables.
@Suite("Claude Code CLI labeller sender")
struct ClaudeCodeCLILabellerSenderTests {
    private static let sampleJSON = """
        {
          "result": "{\\"breaks\\":[]}",
          "session_id": "ses_claude_123",
          "usage": {
            "input_tokens": 735,
            "output_tokens": 15,
            "reasoning_tokens": 71
          }
        }
        """

    private struct Fixture {
        let directory: URL
        var home: URL { directory.appendingPathComponent("home") }
        var script: URL { directory.appendingPathComponent("fake-claude") }
        func recorded(_ name: String) -> Data { (try? Data(contentsOf: directory.appendingPathComponent(name))) ?? Data() }
        func recordedText(_ name: String) -> String { String(decoding: recorded(name), as: UTF8.self) }

        init(output: String = "", status: Int = 0, extra: String = "") throws {
            directory = OwnedTestTemp.root.appendingPathComponent("claude-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try output.write(to: directory.appendingPathComponent("canned.json"), atomically: true, encoding: .utf8)
            let d = directory.path
            let source = """
                #!/bin/sh
                echo ran >> '\(d)/ran'
                for a in "$@"; do echo "$a"; done > '\(d)/args'
                /usr/bin/env > '\(d)/env'
                pwd > '\(d)/cwd'
                \(extra)
                cat > '\(d)/stdin'
                cat '\(d)/canned.json'
                exit \(status)
                """
            try source.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        }

        func sender(timeLimit: Duration = .seconds(30), maximumOutputBytes: Int = ClaudeCodeCLILabellerSender.defaultMaximumOutputBytes) -> ClaudeCodeCLILabellerSender {
            ClaudeCodeCLILabellerSender(
                executableURL: script, homeDirectory: home,
                realHomeDirectory: directory.appendingPathComponent("realhome"),
                timeLimit: timeLimit, maximumOutputBytes: maximumOutputBytes)
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var seen: [LabellerProgress] = []
        var started: Int { lock.withLock { count } }
        var progress: [LabellerProgress] { lock.withLock { seen } }
        func start() { lock.withLock { count += 1 } }
        func report(_ item: LabellerProgress) { lock.withLock { seen.append(item) } }
    }

    private func run(_ sender: ClaudeCodeCLILabellerSender, prompt: String = "hello", model: String = "claude-3-7-sonnet",
                     level: String = "medium", counter: Counter = Counter()) async throws -> LabellerResponse {
        try await sender.send(
            LabellerRequest(prompt: prompt, modelID: model, reasoningLevel: level),
            onRequestStarted: { counter.start() }, onProgress: { counter.report($0) })
    }

    @Test func successRunsTheToolExactlyAsSpecified() async throws {
        let fixture = try Fixture(output: Self.sampleJSON)
        let prompt = String(repeating: "transcript é ", count: 54_000)
        #expect(prompt.utf8.count > 700_000)
        let counter = Counter()
        let response = try await run(fixture.sender(), prompt: prompt, counter: counter)
        #expect(response.text == #"{"breaks":[]}"#)
        #expect(response.usage == LabellerUsage(promptTokens: 735, completionTokens: 15, reasoningTokens: 71))
        #expect(response.requestCount == 1)
        #expect(counter.started == 1)
        #expect(counter.progress.last?.failure == nil)

        let args = fixture.recordedText("args")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .dropLast()
            .map(String.init)
        #expect(args == [
            "-p", "--model", "claude-3-7-sonnet", "--effort", "medium",
            "--tools", "", "--no-session-persistence", "--output-format", "json",
            "--setting-sources", "", "--disable-slash-commands"
        ])
        #expect(!args.contains { $0.contains("transcript") })
        #expect(fixture.recorded("stdin") == Data(prompt.utf8))

        let expectedWork = fixture.home.appendingPathComponent("work").path
        let recordedWork = fixture.recordedText("cwd").trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(recordedWork == expectedWork || recordedWork == "/private" + expectedWork)

        let ignored: Set<String> = ["PWD", "SHLVL", "_", "OLDPWD", "__CF_USER_TEXT_ENCODING"]
        var environment: [String: String] = [:]
        for line in fixture.recordedText("env").split(separator: "\n") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let name = String(line[..<equals])
            if !ignored.contains(name) { environment[name] = String(line[line.index(after: equals)...]) }
        }
        let real = fixture.directory.appendingPathComponent("realhome")
        #expect(environment == [
            "HOME": real.path,
            "PATH": "/usr/bin:/bin",
            "CLAUDE_CODE_DISABLE_CLAUDE_MDS": "1"
        ])
    }

    @Test func errorEventMapsToModelUnavailableWithoutKeepingTheMessage() async throws {
        let json = #"{"is_error":true,"error":{"type":"model_not_found","message":"Model unavailable: secret"}}"#
        let fixture = try Fixture(output: json, status: 1)
        let counter = Counter()
        var thrown: (any Error)?
        do { _ = try await run(fixture.sender(), counter: counter) } catch { thrown = error }
        #expect(thrown as? LabellerFailure == .modelUnavailable)
        #expect(counter.progress.first?.failure == LabellerFailureDetail(status: 0, errorType: "model_not_found"))
        #expect(!String(describing: thrown as Any).contains("secret"))
        #expect(!String(describing: counter.progress).contains("secret"))
    }

    @Test(arguments: [
        ("not signed in", LabellerFailure.keyRejected),
        ("Not signed in to Claude Code", .keyRejected),
        ("auth.failed", .keyRejected),
        ("bad.credentials", .keyRejected),
        ("permission.denied", .keyRejected),
        ("rate.exceeded", .rateLimited(retryAfter: nil)),
        ("rate_limit_error", .rateLimited(retryAfter: nil)),
        ("quota.hit", .usageLimit),
        ("usage.cap", .usageLimit),
        ("usage_limit_exceeded", .usageLimit),
        ("billing.due", .usageLimit),
        ("limit", .usageLimit),
        ("model not found", .modelUnavailable),
        ("some.model-gone", .modelUnavailable),
        ("provider.no-route", .modelUnavailable),
        ("time.limit", .temporary),
        ("text.generate", .temporary),
        ("boom", .temporary)
    ])
    func errorTypesMapInOrder(type: String, expected: LabellerFailure) {
        let json = #"{"is_error":true,"error":{"type":"\#(type)","message":"x"}}"#
        let parsed = ClaudeCodeCLILabellerSender.parse(output: Data(json.utf8))
        #expect(parsed.hasError)
        #expect(ClaudeCodeCLILabellerSender.failure(forErrorType: parsed.errorType) == expected)
        #expect(ClaudeCodeCLILabellerSender.failure(forErrorType: nil) == .temporary)
    }

    @Test func parserExtractsUsageAndSessionAndError() {
        let json = #"""
            {
              "result": "{\"breaks\":[]}",
              "session_id": "ses_xyz",
              "usage": {"input_tokens": 10, "output_tokens": 20, "reasoning_tokens": 30}
            }
            """#
        let parsed = ClaudeCodeCLILabellerSender.parse(output: Data(json.utf8))
        #expect(parsed.text == "{\"breaks\":[]}")
        #expect(parsed.usage == LabellerUsage(promptTokens: 10, completionTokens: 20, reasoningTokens: 30))
        #expect(parsed.sessionID == "ses_xyz")
        #expect(!parsed.hasError)
    }

    @Test func nonZeroExitWithNoOutputIsTemporary() async throws {
        let fixture = try Fixture(status: 1)
        await #expect(throws: LabellerFailure.temporary) { try await run(fixture.sender()) }
    }

    @Test func whitespaceOnlyAnswerIsUnusable() async throws {
        let fixture = try Fixture(output: #"{"result":"  \n "}"#)
        await #expect(throws: LabellerFailure.unusableAnswer) { try await run(fixture.sender()) }
    }

    @Test(arguments: ["bad model", "a;b", ""])
    func unsafeModelIDIsRefusedWithoutRunning(model: String) async throws {
        let fixture = try Fixture(output: Self.sampleJSON)
        let counter = Counter()
        await #expect(throws: LabellerFailure.modelUnavailable) { try await run(fixture.sender(), model: model, counter: counter) }
        await #expect(throws: LabellerFailure.modelUnavailable) { try await run(fixture.sender(), level: "lo w", counter: counter) }
        #expect(counter.started == 0)
        #expect(fixture.recorded("ran").isEmpty)
    }

    @Test func missingExecutableIsTemporaryAfterTheStartCallback() async throws {
        let directory = OwnedTestTemp.root.appendingPathComponent("claude-\(UUID().uuidString)")
        let sender = ClaudeCodeCLILabellerSender(
            executableURL: directory.appendingPathComponent("nope"), homeDirectory: directory.appendingPathComponent("home"),
            realHomeDirectory: directory)
        let counter = Counter()
        await #expect(throws: LabellerFailure.temporary) { try await run(sender, counter: counter) }
        #expect(counter.started == 1)
        #expect(!ClaudeCodeCLILabellerSender.isAvailable(executableURL: directory.appendingPathComponent("nope")))
    }

    @Test func outputCapExceededIsTemporary() async throws {
        let fixture = try Fixture(output: String(repeating: "overflow-data\n", count: 100))
        await #expect(throws: LabellerFailure.temporary) {
            try await run(fixture.sender(maximumOutputBytes: 50))
        }
    }

    @Test func timeLimitKillsTheChildPromptly() async throws {
        let fixture = try Fixture(extra: "sleep 60")
        let started = ContinuousClock.now
        await #expect(throws: LabellerFailure.temporary) { try await run(fixture.sender(timeLimit: .milliseconds(300))) }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func cancellationKillsTheChildPromptly() async throws {
        let fixture = try Fixture(extra: "sleep 60")
        let sender = fixture.sender()
        let started = ContinuousClock.now
        let task = Task { try await run(sender) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - started < .seconds(5))
    }
}
