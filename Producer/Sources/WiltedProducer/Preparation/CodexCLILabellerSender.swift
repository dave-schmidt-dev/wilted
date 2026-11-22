import Foundation
import os

/// Sends one labelling request by running the Codex command-line tool (`codex exec`)
/// non-interactively as a subprocess. It conforms to ``LabellerSending``, so answer validation
/// and records are unchanged.
///
/// The prompt goes only to the child's standard input; the child's standard error is never read;
/// provider message text is never kept, returned, thrown or logged.
public struct CodexCLILabellerSender: LabellerSending {
    /// Where Homebrew installs the tool.
    public static let defaultExecutableURL = URL(fileURLWithPath: "/opt/homebrew/bin/codex")
    /// The name this transport goes by in records.
    public static let transportName = "codex-cli"
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

    /// Makes the private config folder and links only the sign-in file into it from the real one.
    /// The file's contents are never read here. A missing sign-in file leaves the tool signed out.
    static func prepareConfigFolder(homeDirectory: URL, realHomeDirectory: URL) {
        let folder = homeDirectory.appendingPathComponent("codex-home", isDirectory: true)
        let link = folder.appendingPathComponent("auth.json")
        let source = realHomeDirectory.appendingPathComponent(".codex/auth.json")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard !FileManager.default.fileExists(atPath: link.path) else { return }
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
    }

    /// Whether an executable file exists at `executableURL`.
    public static func isAvailable(executableURL: URL = defaultExecutableURL) -> Bool {
        FileManager.default.isExecutableFile(atPath: executableURL.path)
    }

    /// The tool's arguments for a request with an optional working directory. Pure. Never includes the prompt.
    public static func arguments(for request: LabellerRequest, directory: URL? = nil) -> [String] {
        var args = [
            "exec",
            "-m", request.modelID,
            "-c", "model_reasoning_effort=\(request.reasoningLevel)",
            "-s", "read-only",
            "--ephemeral",
            "--ignore-user-config",
            "--ignore-rules",
            "--skip-git-repo-check",
            "--json"
        ]
        if let directory {
            args.append(contentsOf: ["-C", directory.path])
        }
        args.append("-")
        return args
    }

    /// The tool's arguments for a request. Pure. Never includes the prompt.
    public static func arguments(for request: LabellerRequest) -> [String] {
        arguments(for: request, directory: nil)
    }

    /// The child's minimal environment: nothing inherited. Pure.
    public static func environment(homeDirectory: URL, realHomeDirectory: URL) -> [String: String] {
        [
            "HOME": homeDirectory.path,
            "PATH": "/usr/bin:/bin",
            // A private config folder, so the owner's global instruction files are not read.
            // Only the sign-in file is linked in (see `prepareConfigFolder`).
            "CODEX_HOME": homeDirectory.appendingPathComponent("codex-home").path
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
        if let tokens = dict["tokens"] as? [String: Any] {
            parsed.usage = parseUsage(tokens)
        }

        if !parsed.hasError {
            if let result = dict["result"] as? String {
                parsed.text += result
            } else if let text = dict["text"] as? String {
                parsed.text += text
            } else if let message = dict["message"] as? String {
                parsed.text += message
            } else if let part = dict["part"] as? [String: Any], let partText = part["text"] as? String {
                parsed.text += partText
            } else if let item = dict["item"] as? [String: Any] {
                if let contentList = item["content"] as? [[String: Any]] {
                    for content in contentList {
                        if let contentText = content["text"] as? String {
                            parsed.text += contentText
                        }
                    }
                } else if let contentStr = item["content"] as? String {
                    parsed.text += contentStr
                } else if item["type"] as? String == "agent_message", let itemText = item["text"] as? String {
                    // The tool's own event: {"type":"item.completed","item":{"type":"agent_message","text":...}}.
                    parsed.text += itemText
                }
            }
        } else if parsed.errorType == nil {
            if let result = dict["result"] as? String {
                parsed.errorType = cleanErrorType(result)
            } else if let message = dict["message"] as? String {
                parsed.errorType = cleanErrorType(message)
            }
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
        Self.prepareConfigFolder(homeDirectory: homeDirectory, realHomeDirectory: realHomeDirectory)
        let environment = Self.environment(homeDirectory: homeDirectory, realHomeDirectory: realHomeDirectory)
        let child = CodexChild(
            executableURL: executableURL, arguments: Self.arguments(for: request, directory: work),
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
enum CodexChildOutcome: Equatable, Sendable {
    case exited(Int32)
    case launchFailed
    case timedOut
    case overflow
    case cancelled
}

/// One subprocess run: pipes, deadline, kill escalation. The first outcome to settle wins.
final class CodexChild: @unchecked Sendable {
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
    private var outcome: CodexChildOutcome?
    private var continuation: CheckedContinuation<CodexChildOutcome, Never>?
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
    func run() async -> CodexChildOutcome {
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

    private func waitForOutcome() async -> CodexChildOutcome {
        await withCheckedContinuation { (next: CheckedContinuation<CodexChildOutcome, Never>) in
            let ready = lock.withLock { () -> CodexChildOutcome? in
                if let outcome { return outcome }
                continuation = next
                return nil
            }
            if let ready { next.resume(returning: ready) }
        }
    }

    /// Records the first outcome, stops the reader, kills the child unless it exited itself,
    /// and wakes the waiter.
    func settle(_ result: CodexChildOutcome) {
        let (won, waiting, item) = lock.withLock { () -> (Bool, CheckedContinuation<CodexChildOutcome, Never>?, DispatchWorkItem?) in
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
