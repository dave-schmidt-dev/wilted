import Foundation
import os

/// Sends one labelling request by running the Claude Code command-line tool (`claude -p`)
/// non-interactively as a subprocess. It conforms to ``LabellerSending``, so answer validation
/// and records are unchanged.
///
/// The prompt goes only to the child's standard input; the child's standard error is never read;
/// provider message text is never kept, returned, thrown or logged.
public struct ClaudeCodeCLILabellerSender: LabellerSending {
    /// Where Homebrew installs the tool.
    public static let defaultExecutableURL = URL(fileURLWithPath: "/opt/homebrew/bin/claude")
    /// The name this transport goes by in records.
    public static let transportName = "claude-cli"
    /// The largest standard output accepted before the child is killed.
    public static let defaultMaximumOutputBytes = 8 * 1_024 * 1_024

    private let executableURL: URL
    private let homeDirectory: URL
    private let realHomeDirectory: URL
    private let timeLimit: Duration
    private let maximumOutputBytes: Int

    /// - Parameters:
    ///   - executableURL: the tool to run.
    ///   - homeDirectory: a private directory used as the child's `HOME` and working area.
    ///   - realHomeDirectory: the real home, from which credentials and configuration are resolved.
    ///   - timeLimit: how long one call may take before the child is killed.
    ///   - maximumOutputBytes: the largest standard output accepted before the child is killed.
    public init(
        executableURL: URL = defaultExecutableURL,
        homeDirectory: URL,
        realHomeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        timeLimit: Duration = .seconds(900),
        maximumOutputBytes: Int = defaultMaximumOutputBytes
    ) {
        self.executableURL = executableURL
        self.homeDirectory = homeDirectory
        self.realHomeDirectory = realHomeDirectory
        self.timeLimit = timeLimit
        self.maximumOutputBytes = maximumOutputBytes
    }

    /// Whether an executable file exists at `executableURL`.
    public static func isAvailable(executableURL: URL = defaultExecutableURL) -> Bool {
        FileManager.default.isExecutableFile(atPath: executableURL.path)
    }

    /// The tool's arguments for a request. Pure. Never includes the prompt.
    public static func arguments(for request: LabellerRequest) -> [String] {
        [
            "-p",
            "--model", request.modelID,
            "--effort", request.reasoningLevel,
            "--tools", "",
            "--no-session-persistence",
            "--output-format", "json",
            "--setting-sources", "",
            "--disable-slash-commands"
        ]
    }

    /// The child's minimal environment: nothing inherited. Pure.
    public static func environment(homeDirectory: URL, realHomeDirectory: URL) -> [String: String] {
        [
            // The tool finds its sign-in through the real home; a private home reads as signed out.
            // The owner's global instruction files are switched off instead.
            "HOME": realHomeDirectory.path,
            // The sign-in lives in the login keychain under the account name, which the tool takes
            // from these. Without them it reports "Not logged in" although the owner is signed in.
            "USER": realHomeDirectory.lastPathComponent,
            "LOGNAME": realHomeDirectory.lastPathComponent,
            "PATH": "/usr/bin:/bin",
            "CLAUDE_CODE_DISABLE_CLAUDE_MDS": "1"
        ]
    }

    /// What one run's standard output said.
    public struct ParsedOutput: Equatable, Sendable {
        /// The parsed response text.
        public var text = ""
        /// Usage reported by the tool.
        public var usage = LabellerUsage()
        /// The session ID seen, if any.
        public var sessionID: String?
        /// Whether an error occurred.
        public var hasError = false
        /// The sanitized error type.
        public var errorType: String?

        public init(
            text: String = "",
            usage: LabellerUsage = LabellerUsage(),
            sessionID: String? = nil,
            hasError: Bool = false,
            errorType: String? = nil
        ) {
            self.text = text
            self.usage = usage
            self.sessionID = sessionID
            self.hasError = hasError
            self.errorType = errorType
        }
    }

    /// Parses JSON or JSON Lines output. Pure; provider message text is never read or stored.
    public static func parse(output: Data) -> ParsedOutput {
        var parsed = ParsedOutput()
        if let json = try? JSONSerialization.jsonObject(with: output) as? [String: Any] {
            parseDictionary(json, into: &parsed)
            return parsed
        }
        for line in output.split(separator: 0x0A) {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            parseDictionary(event, into: &parsed)
        }
        return parsed
    }

    private static func parseDictionary(_ dict: [String: Any], into parsed: inout ParsedOutput) {
        if let isError = dict["is_error"] as? Bool, isError {
            parsed.hasError = true
        }
        if let errorObj = dict["error"] as? [String: Any] {
            parsed.hasError = true
            if let type = errorObj["type"] as? String {
                parsed.errorType = cleanErrorType(type)
            }
        }
        let eventType = dict["type"] as? String
        if eventType == "error" {
            parsed.hasError = true
            if let errorObj = dict["error"] as? [String: Any], let errType = errorObj["type"] as? String {
                parsed.errorType = cleanErrorType(errType)
            } else if parsed.errorType == nil {
                parsed.errorType = cleanErrorType(eventType)
            }
        }
        if let sessionID = dict["session_id"] as? String ?? dict["sessionID"] as? String {
            parsed.sessionID = sessionID
        }
        if let usageObj = dict["usage"] as? [String: Any] {
            parsed.usage = parseUsage(usageObj)
        }
        if let result = dict["result"] as? String {
            if parsed.hasError {
                if parsed.errorType == nil { parsed.errorType = cleanErrorType(result) }
            } else {
                parsed.text = result
            }
        } else if let text = dict["text"] as? String {
            if !parsed.hasError { parsed.text = text }
        }
    }

    private static func parseUsage(_ dict: [String: Any]) -> LabellerUsage {
        let prompt = dict["input_tokens"] as? Int ?? dict["prompt_tokens"] as? Int ?? dict["input"] as? Int
        let completion = dict["output_tokens"] as? Int ?? dict["completion_tokens"] as? Int ?? dict["output"] as? Int
        let reasoning = dict["reasoning_tokens"] as? Int ?? dict["reasoning"] as? Int
        return LabellerUsage(promptTokens: prompt, completionTokens: completion, reasoningTokens: reasoning)
    }

    private static func cleanErrorType(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.- ")
        let cleaned = String(raw.filter { allowed.contains($0) }.prefix(48)).trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Maps an error type to a failure, checked in order. Pure.
    public static func failure(forErrorType type: String?) -> LabellerFailure {
        let words = (type ?? "").lowercased().split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
        func has(_ prefixes: [String]) -> Bool { words.contains { word in prefixes.contains { word.hasPrefix($0) } } }
        func hasWord(_ exact: [String]) -> Bool { words.contains { exact.contains(String($0)) } }

        if words.contains("notsignedin")
            || (words.contains("signed") && words.contains("in"))
            || words.contains("signin")
            || words.contains("login")
            || has(["auth", "credential", "permission"]) {
            return .keyRejected
        }
        if hasWord(["rate", "ratelimit"]) {
            return .rateLimited(retryAfter: nil)
        }
        if hasWord(["quota", "usage", "billing"]) || (hasWord(["limit"]) && !hasWord(["time"])) {
            return .usageLimit
        }
        if hasWord(["route", "model"]) {
            return .modelUnavailable
        }
        return .temporary
    }

    private static func isSafeToken(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }

    /// Performs one labelling request.
    ///
    /// `onRequestStarted` fires exactly once, immediately before the process is launched,
    /// including when the launch then fails. Cancelling the surrounding task kills the child
    /// and throws `CancellationError`.
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
        } catch {
            throw LabellerFailure.temporary
        }
        let environment = Self.environment(homeDirectory: homeDirectory, realHomeDirectory: realHomeDirectory)
        let child = ClaudeCodeChild(
            executableURL: executableURL, arguments: Self.arguments(for: request),
            environment: environment, directory: work, input: Data(request.prompt.utf8),
            timeLimit: timeLimit, maximumOutputBytes: maximumOutputBytes)
        onRequestStarted()
        let outcome = await withTaskCancellationHandler {
            await child.run()
        } onCancel: {
            child.settle(.cancelled)
        }
        let parsed = Self.parse(output: child.output)
        switch outcome {
        case .cancelled:
            throw CancellationError()
        case .launchFailed, .timedOut, .overflow:
            throw LabellerFailure.temporary
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
enum ClaudeCodeChildOutcome: Equatable, Sendable {
    case exited(Int32)
    case launchFailed
    case timedOut
    case overflow
    case cancelled
}

/// One subprocess run: pipes, deadline, kill escalation. The first outcome to settle wins.
final class ClaudeCodeChild: @unchecked Sendable {
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
    private var outcome: ClaudeCodeChildOutcome?
    private var continuation: CheckedContinuation<ClaudeCodeChildOutcome, Never>?
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
    func run() async -> ClaudeCodeChildOutcome {
        if let settled = lock.withLock({ outcome }) { return settled }
        process.standardInput = input == nil ? FileHandle.nullDevice : inputPipe
        process.standardOutput = maximumOutputBytes > 0 ? outputPipe : FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [self] child in
            let finished = lock.withLock { () -> Bool in exitStatus = child.terminationStatus; return reachedEnd }
            if finished {
                settle(.exited(child.terminationStatus))
            } else {
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

    private func waitForOutcome() async -> ClaudeCodeChildOutcome {
        await withCheckedContinuation { (next: CheckedContinuation<ClaudeCodeChildOutcome, Never>) in
            let ready = lock.withLock { () -> ClaudeCodeChildOutcome? in
                if let outcome { return outcome }
                continuation = next
                return nil
            }
            if let ready { next.resume(returning: ready) }
        }
    }

    /// Records the first outcome, stops the reader, kills the child unless it exited itself,
    /// and wakes the waiter.
    func settle(_ result: ClaudeCodeChildOutcome) {
        let (won, waiting, item) = lock.withLock { () -> (Bool, CheckedContinuation<ClaudeCodeChildOutcome, Never>?, DispatchWorkItem?) in
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
