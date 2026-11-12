import Foundation
import Testing
@testable import WiltedProducer

/// The OpenCode command-line sender, driven through fake `/bin/sh` executables.
@Suite("OpenCode CLI labeller sender")
struct OpenCodeCLILabellerSenderTests {
    private static let textLines = """
        {"type":"text","part":{"sessionID":"ses_abc123","text":"{\\"breaks\\":"}}
        not json at all
        {"type":"text","part":{"sessionID":"ses_abc123","text":"[]}"}}
        {"type":"step_finish","part":{"sessionID":"ses_abc123","tokens":{"input":735,"output":15,"reasoning":71,"cache":{"read":0}}}}
        """

    private struct Fixture {
        let directory: URL
        var home: URL { directory.appendingPathComponent("home") }
        var script: URL { directory.appendingPathComponent("fake-opencode") }
        func recorded(_ name: String) -> Data { (try? Data(contentsOf: directory.appendingPathComponent(name))) ?? Data() }
        func recordedText(_ name: String) -> String { String(decoding: recorded(name), as: UTF8.self) }

        /// Writes the fake tool: records its call, prints `body`, exits with `status`.
        init(output: String = "", status: Int = 0, extra: String = "") throws {
            directory = OwnedTestTemp.root.appendingPathComponent("opencode-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try output.write(to: directory.appendingPathComponent("canned.jsonl"), atomically: true, encoding: .utf8)
            let d = directory.path
            let source = """
                #!/bin/sh
                if [ "$1" = "session" ]; then echo "$@" >> '\(d)/session-args'; exit 0; fi
                echo ran >> '\(d)/ran'
                for a in "$@"; do echo "$a"; done > '\(d)/args'
                /usr/bin/env > '\(d)/env'
                pwd > '\(d)/cwd'
                \(extra)
                cat > '\(d)/stdin'
                cat '\(d)/canned.jsonl'
                exit \(status)
                """
            try source.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        }

        func sender(timeLimit: Duration = .seconds(30)) -> OpenCodeCLILabellerSender {
            OpenCodeCLILabellerSender(
                executableURL: script, homeDirectory: home,
                realHomeDirectory: directory.appendingPathComponent("realhome"), timeLimit: timeLimit,
                sessionDeleteLimit: .seconds(5))
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

    private func run(_ sender: OpenCodeCLILabellerSender, prompt: String = "hello", model: String = "deepseek-v4.1-flash",
                     level: String = "low", counter: Counter = Counter()) async throws -> LabellerResponse {
        try await sender.send(
            LabellerRequest(prompt: prompt, modelID: model, reasoningLevel: level),
            onRequestStarted: { counter.start() }, onProgress: { counter.report($0) })
    }

    @Test func successRunsTheToolExactlyAsSpecified() async throws {
        let fixture = try Fixture(output: Self.textLines)
        let prompt = String(repeating: "transcript é ", count: 54_000)
        #expect(prompt.utf8.count > 700_000)
        let counter = Counter()
        let response = try await run(fixture.sender(), prompt: prompt, counter: counter)
        #expect(response.text == #"{"breaks":[]}"#)
        #expect(response.usage == LabellerUsage(promptTokens: 735, completionTokens: 15, reasoningTokens: 71))
        #expect(response.requestCount == 1)
        #expect(counter.started == 1)
        #expect(counter.progress.last?.failure == nil)
        #expect(fixture.recordedText("args").split(separator: "\n").map(String.init) == [
            "run", "--standalone", "--title", "wilted-labeller", "--agent", "labeller",
            "--model", "opencode-go/deepseek-v4.1-flash#low", "--format", "json"])
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
            "HOME": fixture.home.path, "PATH": "/usr/bin:/bin",
            "XDG_CONFIG_HOME": fixture.home.path + "/config",
            "XDG_DATA_HOME": real.path + "/.local/share", "XDG_CACHE_HOME": real.path + "/.cache",
            "XDG_STATE_HOME": real.path + "/.local/state"])
        let config = try String(contentsOf: fixture.home.appendingPathComponent("work/opencode.jsonc"), encoding: .utf8)
        #expect(config == OpenCodeCLILabellerSender.agentConfiguration)
        #expect(fixture.recordedText("session-args").trimmingCharacters(in: .whitespacesAndNewlines)
            == "session delete ses_abc123")
    }

    @Test func errorEventMapsToModelUnavailableWithoutKeepingTheMessage() async throws {
        let line = #"{"type":"error","error":{"type":"provider.no-route","message":"Model unavailable: secret"}}"#
        let fixture = try Fixture(output: line, status: 1)
        let counter = Counter()
        var thrown: (any Error)?
        do { _ = try await run(fixture.sender(), counter: counter) } catch { thrown = error }
        #expect(thrown as? LabellerFailure == .modelUnavailable)
        #expect(counter.progress.first?.failure == LabellerFailureDetail(status: 0, errorType: "provider.no-route"))
        #expect(!String(describing: thrown as Any).contains("secret"))
        #expect(!String(describing: counter.progress).contains("secret"))
    }

    @Test(arguments: [
        ("provider.no-route", LabellerFailure.modelUnavailable), ("some.model-gone", .modelUnavailable),
        ("auth.failed", .keyRejected), ("bad.credentials", .keyRejected), ("permission.denied", .keyRejected),
        ("rate.exceeded", .rateLimited(retryAfter: nil)), ("quota.hit", .usageLimit), ("usage.cap", .usageLimit),
        ("billing.due", .usageLimit), ("usage_limit_exceeded", .usageLimit),
        ("rate_limit_error", .rateLimited(retryAfter: nil)), ("authentication_error", .keyRejected),
        ("time.limit", .temporary), ("text.generate", .temporary), ("boom", .temporary)])
    func errorTypesMapInOrder(type: String, expected: LabellerFailure) {
        let line = #"{"type":"error","error":{"type":"\#(type)","message":"x"}}"#
        let parsed = OpenCodeCLILabellerSender.parse(output: Data(line.utf8))
        #expect(parsed.hasError)
        #expect(OpenCodeCLILabellerSender.failure(forErrorType: parsed.errorType) == expected)
        #expect(OpenCodeCLILabellerSender.failure(forErrorType: nil) == .temporary)
    }

    @Test func parserUsesTheLastStepFinishAndFirstSessionAndCleansTheType() {
        let output = """
            {"type":"step_finish","sessionID":"bad id","part":{"tokens":{"input":1,"output":2,"reasoning":3}}}
            {"type":"step_finish","part":{"sessionID":"ses_Z9","tokens":{"input":10,"output":20,"reasoning":30}}}
            {"type":"error","error":{"type":"A b;c/d.e"}}
            """
        let parsed = OpenCodeCLILabellerSender.parse(output: Data(output.utf8))
        #expect(parsed.usage == LabellerUsage(promptTokens: 10, completionTokens: 20, reasoningTokens: 30))
        #expect(parsed.sessionID == "ses_Z9")
        #expect(parsed.errorType == "Abcd.e")
    }

    @Test func nonZeroExitWithNoOutputIsTemporary() async throws {
        let fixture = try Fixture(status: 1)
        await #expect(throws: LabellerFailure.temporary) { try await run(fixture.sender()) }
    }

    @Test func whitespaceOnlyAnswerIsUnusable() async throws {
        let fixture = try Fixture(output: #"{"type":"text","part":{"sessionID":"ses_q1","text":"  \n "}}"#)
        await #expect(throws: LabellerFailure.unusableAnswer) { try await run(fixture.sender()) }
    }

    @Test(arguments: ["bad model", "a;b", ""])
    func unsafeModelIDIsRefusedWithoutRunning(model: String) async throws {
        let fixture = try Fixture(output: Self.textLines)
        let counter = Counter()
        await #expect(throws: LabellerFailure.modelUnavailable) { try await run(fixture.sender(), model: model, counter: counter) }
        await #expect(throws: LabellerFailure.modelUnavailable) { try await run(fixture.sender(), level: "lo w", counter: counter) }
        #expect(counter.started == 0)
        #expect(fixture.recorded("ran").isEmpty)
    }

    @Test func missingExecutableIsTemporaryAfterTheStartCallback() async throws {
        let directory = OwnedTestTemp.root.appendingPathComponent("opencode-\(UUID().uuidString)")
        let sender = OpenCodeCLILabellerSender(
            executableURL: directory.appendingPathComponent("nope"), homeDirectory: directory.appendingPathComponent("home"),
            realHomeDirectory: directory)
        let counter = Counter()
        await #expect(throws: LabellerFailure.temporary) { try await run(sender, counter: counter) }
        #expect(counter.started == 1)
        #expect(!OpenCodeCLILabellerSender.isAvailable(executableURL: directory.appendingPathComponent("nope")))
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

    @Test func preferenceDefaultsOffAndRoundTrips() throws {
        let suite = "wilted-opencode-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AdLabellerPreferences(preferences: defaults)
        #expect(preferences.usesOpenCodeCLI == false)
        preferences.usesOpenCodeCLI = true
        #expect(preferences.usesOpenCodeCLI)
        #expect(defaults.bool(forKey: "wilted.adLabeller.useOpenCodeCLI"))
        preferences.usesOpenCodeCLI = false
        #expect(preferences.usesOpenCodeCLI == false)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WILTED_LIVE_OPENCODE_CLI"] == "1"))
    func liveRun() async throws {
        let home = OwnedTestTemp.root.appendingPathComponent("live-\(UUID().uuidString)")
        let sender = OpenCodeCLILabellerSender(homeDirectory: home)
        let prompt = #"Transcript cues: [0] 0.0-5.0 welcome. [1] 5.0-35.0 this episode is sponsored by Example Mattress, use code SHOW. [2] 35.0-60.0 back to the guest. Reply with only {"breaks":[{"start":seconds,"end":seconds}]}."#
        let response = try await run(sender, prompt: prompt)
        #expect(response.text.contains("\"breaks\""))
    }
}
