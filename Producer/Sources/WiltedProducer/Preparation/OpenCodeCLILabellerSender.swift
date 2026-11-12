import Foundation
import os

/// Sends one labelling request by running the signed-in OpenCode command-line tool as a
/// subprocess, for the case where the provider refuses the HTTP key. It conforms to
/// ``LabellerSending``, so answer validation and records are unchanged.
///
/// The only thing logged is a warning that a stored session may be left behind. The prompt goes
/// only to the child's standard input; the child's standard error is never read; provider
/// message text is never kept, returned, thrown or logged.
public struct OpenCodeCLILabellerSender: LabellerSending {
    /// Where Homebrew installs the tool.
    public static let defaultExecutableURL = URL(fileURLWithPath: "/opt/homebrew/bin/opencode")
    /// The name this transport goes by in records.
    public static let transportName = "opencode-cli"
    /// The largest standard output accepted before the child is killed.
    static let maximumOutputBytes = 8 * 1_024 * 1_024
    /// The configuration file written beside the child's working directory: one tool-less agent.
    static let agentConfiguration = """
        {
          "$schema": "https://opencode.ai/config.json",
          "default_agent": "labeller",
          "agents": {
            "labeller": {
              "mode": "primary",
              "description": "Labels advertising breaks; no tools",
              "system": "Follow the user's message exactly. You have no tools. Reply with text only.",
              "permissions": [ { "action": "*", "resource": "*", "effect": "deny" } ]
            }
          }
        }
        """

    private let executableURL: URL
    private let homeDirectory: URL
    private let realHomeDirectory: URL
    private let timeLimit: Duration
    private let sessionDeleteLimit: Duration

    /// - Parameters:
    ///   - executableURL: the tool to run.
    ///   - homeDirectory: a private directory used as the child's `HOME` and working area.
    ///   - realHomeDirectory: the real home, whose data, cache and state directories the tool shares.
    ///   - timeLimit: how long one call may take before the child is killed.
    ///   - sessionDeleteLimit: how long the follow-up session deletion may take.
    public init(
        executableURL: URL = defaultExecutableURL, homeDirectory: URL,
        realHomeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        timeLimit: Duration = .seconds(900), sessionDeleteLimit: Duration = .seconds(30)
    ) {
        self.executableURL = executableURL
        self.homeDirectory = homeDirectory
        self.realHomeDirectory = realHomeDirectory
        self.timeLimit = timeLimit
        self.sessionDeleteLimit = sessionDeleteLimit
    }

    /// Whether an executable file exists at `executableURL`.
    public static func isAvailable(executableURL: URL = defaultExecutableURL) -> Bool {
        FileManager.default.isExecutableFile(atPath: executableURL.path)
    }

    /// The tool's arguments for a request. Pure. Never includes `--auto`.
    public static func arguments(for request: LabellerRequest) -> [String] {
        ["run", "--standalone", "--title", "wilted-labeller", "--agent", "labeller",
         "--model", "opencode-go/\(request.modelID)#\(request.reasoningLevel)", "--format", "json"]
    }

    /// The child's whole environment: six variables, nothing inherited. Pure.
    public static func environment(homeDirectory: URL, realHomeDirectory: URL) -> [String: String] {
        ["HOME": homeDirectory.path, "PATH": "/usr/bin:/bin",
         "XDG_CONFIG_HOME": homeDirectory.appendingPathComponent("config").path,
         "XDG_DATA_HOME": realHomeDirectory.appendingPathComponent(".local/share").path,
         "XDG_CACHE_HOME": realHomeDirectory.appendingPathComponent(".cache").path,
         "XDG_STATE_HOME": realHomeDirectory.appendingPathComponent(".local/state").path]
    }

    /// What one run's standard output said.
    public struct ParsedOutput: Equatable, Sendable {
        /// Every `text` part, joined in order.
        public var text = ""
        /// Usage from the last `step_finish` event.
        public var usage = LabellerUsage()
        /// The first well-formed session ID seen.
        public var sessionID: String?
        /// Whether an `error` event appeared.
        public var hasError = false
        /// The first error event's type, cleaned by ``LabellerClient/failureDetail(status:body:)``.
        public var errorType: String?
    }

    /// Parses JSON Lines output. Pure; lines that are not JSON objects are ignored, and no
    /// provider message text is read.
    public static func parse(output: Data) -> ParsedOutput {
        var parsed = ParsedOutput()
        for line in output.split(separator: 0x0A) {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            let part = event["part"] as? [String: Any]
            if parsed.sessionID == nil {
                for candidate in [part?["sessionID"], event["sessionID"]] {
                    if let id = candidate as? String, isSessionID(id) { parsed.sessionID = id; break }
                }
            }
            switch event["type"] as? String {
            case "text":
                if let text = part?["text"] as? String { parsed.text += text }
            case "step_finish":
                if let tokens = part?["tokens"] as? [String: Any] {
                    parsed.usage = LabellerUsage(
                        promptTokens: tokens["input"] as? Int, completionTokens: tokens["output"] as? Int,
                        reasoningTokens: tokens["reasoning"] as? Int)
                }
            case "error":
                guard !parsed.hasError else { break }
                parsed.hasError = true
                var typeOnly: [String: Any] = [:]
                if let type = (event["error"] as? [String: Any])?["type"] as? String { typeOnly["type"] = type }
                let body = (try? JSONSerialization.data(withJSONObject: ["error": typeOnly])) ?? Data()
                parsed.errorType = LabellerClient.failureDetail(status: 0, body: body).errorType
            default:
                break
            }
        }
        return parsed
    }

    /// Maps an error type to a failure, checked in order. Pure.
    static func failure(forErrorType type: String?) -> LabellerFailure {
        // Whole words, so "generate" is not a rate limit and "time.limit" is not a usage limit.
        let words = (type ?? "").lowercased().split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
        func has(_ prefixes: [String]) -> Bool { words.contains { word in prefixes.contains { word.hasPrefix($0) } } }
        func hasWord(_ exact: [String]) -> Bool { words.contains { exact.contains(String($0)) } }
        if hasWord(["route", "model"]) { return .modelUnavailable }
        if has(["auth", "credential", "permission"]) { return .keyRejected }
        if hasWord(["rate", "ratelimit"]) { return .rateLimited(retryAfter: nil) }
        if hasWord(["quota", "usage", "billing"]) { return .usageLimit }
        return .temporary
    }

    private static let logger = Logger(subsystem: "com.zerodelta.wilted", category: "AdLabellerCLI")

    private static func isSessionID(_ value: String) -> Bool {
        value.hasPrefix("ses_") && value.count > 4
            && value.dropFirst(4).allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    private static func isSafeToken(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }

    /// Performs one labelling request.
    ///
    /// `onRequestStarted` fires exactly once, immediately before the process is launched,
    /// including when the launch then fails. Cancelling the surrounding task kills the child
    /// and throws `CancellationError`. The stored session is deleted afterwards; that result
    /// never changes what this returns or throws.
    public func send(
        _ request: LabellerRequest,
        onRequestStarted: @escaping @Sendable () -> Void,
        onProgress: @escaping @Sendable (LabellerProgress) -> Void
    ) async throws -> LabellerResponse {
        guard Self.isSafeToken(request.modelID), Self.isSafeToken(request.reasoningLevel) else {
            throw LabellerFailure.modelUnavailable
        }
        let work = homeDirectory.appendingPathComponent("work", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: homeDirectory.appendingPathComponent("config", isDirectory: true), withIntermediateDirectories: true)
            try Self.agentConfiguration.write(
                to: work.appendingPathComponent("opencode.jsonc"), atomically: true, encoding: .utf8)
        } catch {
            throw LabellerFailure.temporary
        }
        let environment = Self.environment(homeDirectory: homeDirectory, realHomeDirectory: realHomeDirectory)
        let child = OpenCodeChild(
            executableURL: executableURL, arguments: Self.arguments(for: request),
            environment: environment, directory: work, input: Data(request.prompt.utf8),
            timeLimit: timeLimit, maximumOutputBytes: Self.maximumOutputBytes)
        onRequestStarted()
        let outcome = await withTaskCancellationHandler {
            await child.run()
        } onCancel: {
            child.settle(.cancelled)
        }
        let parsed = Self.parse(output: child.output)
        if let sessionID = parsed.sessionID, outcome != .launchFailed {
            let deletion = OpenCodeChild(
                executableURL: executableURL, arguments: ["session", "delete", sessionID],
                environment: environment, directory: work, input: nil, timeLimit: sessionDeleteLimit,
                maximumOutputBytes: 0)
            let delete: @Sendable () async -> Void = {
                if await deletion.run() != .exited(0) {
                    Self.logger.warning("Stored session \(sessionID, privacy: .public) was not deleted")
                }
            }
            if case .exited = outcome { await delete() } else { Task.detached { await delete() } }
        } else if outcome != .launchFailed {
            Self.logger.warning("A request ended before its stored session could be identified; it was not deleted")
        }
        switch outcome {
        case .cancelled: throw CancellationError()
        case .launchFailed, .timedOut, .overflow: throw LabellerFailure.temporary
        case .exited(let status):
            if parsed.hasError {
                onProgress(LabellerProgress(
                    bytesReceived: child.output.count, answerCharacters: parsed.text.count,
                    failure: LabellerFailureDetail(status: 0, errorType: parsed.errorType)))
                throw Self.failure(forErrorType: parsed.errorType)
            }
            guard status == 0 else { throw LabellerFailure.temporary }
            guard !parsed.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LabellerFailure.unusableAnswer
            }
            onProgress(LabellerProgress(bytesReceived: child.output.count, answerCharacters: parsed.text.count))
            return LabellerResponse(text: parsed.text, usage: parsed.usage)
        }
    }
}

/// How one child run ended.
enum OpenCodeChildOutcome: Equatable, Sendable {
    case exited(Int32)
    case launchFailed
    case timedOut
    case overflow
    case cancelled
}

/// One subprocess run: pipes, deadline, kill escalation. The first outcome to settle wins.
/// State is guarded by `lock`; the class is `@unchecked Sendable` because `Process` is not.
final class OpenCodeChild: @unchecked Sendable {
    private let process = Process()
    private let outputPipe = Pipe()
    private let inputPipe = Pipe()
    private let input: Data?
    private let timeLimit: Duration
    private let maximumOutputBytes: Int
    private let lock = NSLock()
    private var buffer = Data()
    private var exitStatus: Int32?
    private var reachedEnd = false
    private var outcome: OpenCodeChildOutcome?
    private var continuation: CheckedContinuation<OpenCodeChildOutcome, Never>?
    private var deadline: DispatchWorkItem?

    init(executableURL: URL, arguments: [String], environment: [String: String], directory: URL,
         input: Data?, timeLimit: Duration, maximumOutputBytes: Int) {
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        self.input = input
        self.timeLimit = timeLimit
        self.maximumOutputBytes = maximumOutputBytes
    }

    /// Everything read from standard output so far.
    var output: Data { lock.withLock { buffer } }

    /// Launches the child and waits for the first outcome.
    func run() async -> OpenCodeChildOutcome {
        if let settled = lock.withLock({ outcome }) { return settled }
        process.standardInput = input == nil ? FileHandle.nullDevice : inputPipe
        process.standardOutput = maximumOutputBytes > 0 ? outputPipe : FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [self] child in
            let finished = lock.withLock { () -> Bool in exitStatus = child.terminationStatus; return reachedEnd }
            if finished {
                settle(.exited(child.terminationStatus))
            } else {
                // A grandchild may hold the pipe open; take what arrived after a short grace.
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in settle(.exited(child.terminationStatus)) }
            }
        }
        if maximumOutputBytes > 0 {
            outputPipe.fileHandleForReading.readabilityHandler = { [self] handle in
                let chunk = handle.availableData
                let status = lock.withLock { () -> (over: Bool, done: Bool, code: Int32?) in
                    if chunk.isEmpty { reachedEnd = true; return (false, true, exitStatus) }
                    buffer.append(chunk)
                    return (buffer.count > maximumOutputBytes, false, nil)
                }
                if chunk.isEmpty { handle.readabilityHandler = nil }
                if status.over { settle(.overflow) } else if status.done, let code = status.code { settle(.exited(code)) }
            }
        } else {
            lock.withLock { reachedEnd = true }
        }
        do {
            try process.run()
        } catch {
            settle(.launchFailed)
            return await waitForOutcome()
        }
        // A cancel that settled before the launch found nothing to kill; stop the child now.
        if let settled = lock.withLock({ outcome }) {
            if case .exited = settled {} else { kill() }
        }
        if input != nil {
            try? inputPipe.fileHandleForReading.close()
            let writer = inputPipe.fileHandleForWriting
            _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
            let data = input ?? Data()
            DispatchQueue.global().async { try? writer.write(contentsOf: data); try? writer.close() }
        }
        try? outputPipe.fileHandleForWriting.close()
        let seconds = Double(timeLimit.components.seconds) + Double(timeLimit.components.attoseconds) / 1e18
        let item = DispatchWorkItem { [self] in settle(.timedOut) }
        lock.withLock { deadline = item }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: item)
        return await waitForOutcome()
    }

    private func waitForOutcome() async -> OpenCodeChildOutcome {
        await withCheckedContinuation { (next: CheckedContinuation<OpenCodeChildOutcome, Never>) in
            let ready = lock.withLock { () -> OpenCodeChildOutcome? in
                if let outcome { return outcome }
                continuation = next
                return nil
            }
            if let ready { next.resume(returning: ready) }
        }
    }

    /// Records the first outcome, stops the reader, kills the child unless it exited itself,
    /// and wakes the waiter.
    func settle(_ result: OpenCodeChildOutcome) {
        let (won, waiting, item) = lock.withLock { () -> (Bool, CheckedContinuation<OpenCodeChildOutcome, Never>?, DispatchWorkItem?) in
            guard outcome == nil else { return (false, nil, nil) }
            outcome = result
            defer { continuation = nil }
            return (true, continuation, deadline)
        }
        guard won else { return }
        item?.cancel()
        outputPipe.fileHandleForReading.readabilityHandler = nil
        if case .exited = result {} else { kill() }
        waiting?.resume(returning: result)
    }

    private func kill() {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [process] in
            if process.isRunning { Foundation.kill(pid, SIGKILL) }
        }
    }
}
