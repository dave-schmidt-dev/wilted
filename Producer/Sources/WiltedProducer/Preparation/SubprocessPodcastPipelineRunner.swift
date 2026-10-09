import CryptoKit
import Foundation
import WiltedDomain

/// Runs the pipeline worker as a subprocess.
///
/// The worker is Python because the ad detection it wraps is Python: about
/// 1,500 lines of tuned prompts and boundary verification that would lose its
/// tuning in translation. Paths remain configurable for tests and local
/// recovery, while production defaults stay inside this project.
public struct SubprocessPodcastPipelineRunner: PodcastPipelineRunning, Sendable {
    public struct Configuration: Sendable {
        public var interpreterURL: URL
        public var workerURL: URL
        public var pythonPath: URL?
        public var timeout: TimeInterval
        /// Directories appended to the worker's PATH when absent. The cut
        /// shells out to ffmpeg, and an app launched from Finder inherits a
        /// PATH that has never heard of Homebrew.
        public var toolSearchPaths: [String]

        public static let defaultToolSearchPaths = ["/opt/homebrew/bin", "/usr/local/bin"]

        public init(
            interpreterURL: URL,
            workerURL: URL,
            pythonPath: URL? = nil,
            timeout: TimeInterval = 7_200,
            toolSearchPaths: [String] = Configuration.defaultToolSearchPaths
        ) {
            self.interpreterURL = interpreterURL
            self.workerURL = workerURL
            self.pythonPath = pythonPath
            self.timeout = timeout
            self.toolSearchPaths = toolSearchPaths
        }

        /// The PATH the worker runs with: the inherited one, then any search
        /// path it does not already contain, in order. Every named entry is
        /// kept; empty entries, which POSIX reads as the current directory,
        /// are dropped on purpose for a process that shells out to ffmpeg.
        /// Nothing at all falls back to the system default rather than an
        /// empty string, which Python's `shutil.which` treats as no PATH.
        public func workerPATH(inherited: String?) -> String {
            var entries = (inherited ?? "").split(separator: ":", omittingEmptySubsequences: true).map(String.init)
            for path in toolSearchPaths where !path.isEmpty && !entries.contains(path) {
                entries.append(path)
            }
            if entries.isEmpty { return "/usr/bin:/bin:/usr/sbin:/sbin" }
            return entries.joined(separator: ":")
        }

        /// Where the pieces live on this machine, overridable per environment.
        ///
        /// A three-hour episode can spend an hour in speech-to-text and ad
        /// classification, so the default timeout is generous by design: a
        /// tighter one would abandon real work rather than catch a hang.
        public static func resolved(environment: [String: String] = ProcessInfo.processInfo.environment) -> Configuration {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let runtime = home.appending(path: "Documents/Projects/wilted/Producer/Runtime")
            let interpreter = environment["WILTED_PIPELINE_PYTHON"].map { URL(fileURLWithPath: $0) }
                ?? runtime.appending(path: ".venv/bin/python")
            let worker = environment["WILTED_PIPELINE_WORKER"].map { URL(fileURLWithPath: $0) }
                ?? home.appending(path: "Documents/Projects/wilted/Producer/Workers/wilted_pipeline.py")
            let sources = environment["WILTED_PIPELINE_PYTHONPATH"].map { URL(fileURLWithPath: $0) }
                ?? runtime.appending(path: "src")
            let timeout = environment["WILTED_PIPELINE_TIMEOUT_S"].flatMap(TimeInterval.init) ?? 7_200
            let toolSearchPaths = environment["WILTED_PIPELINE_TOOL_PATH"]
                .map { $0.split(separator: ":", omittingEmptySubsequences: true).map(String.init) }
                ?? defaultToolSearchPaths
            return Configuration(interpreterURL: interpreter, workerURL: worker,
                                 pythonPath: sources, timeout: timeout, toolSearchPaths: toolSearchPaths)
        }
    }

    public let configuration: Configuration

    public init(configuration: Configuration = .resolved()) {
        self.configuration = configuration
    }

    public func run(
        request: Data,
        onProgress: @escaping @Sendable (PodcastPreparationProgress) -> Void
    ) async throws -> Data {
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: configuration.interpreterURL.path) else {
            throw PodcastPreparationError.workerUnavailable(
                "no interpreter at \(configuration.interpreterURL.path); run "
                + "`uv sync --project Producer/Runtime --locked` from ~/Documents/Projects/wilted "
                + "or set WILTED_PIPELINE_PYTHON"
            )
        }
        guard fileManager.fileExists(atPath: configuration.workerURL.path) else {
            throw PodcastPreparationError.workerUnavailable("no worker at \(configuration.workerURL.path)")
        }
        if let pythonPath = configuration.pythonPath {
            let requiredRuntimeSource = pythonPath.appending(path: "wilted/ads.py")
            guard fileManager.fileExists(atPath: requiredRuntimeSource.path) else {
                throw PodcastPreparationError.workerUnavailable(
                    "no Wilted runtime source at \(requiredRuntimeSource.path); "
                    + "restore Producer/Runtime/src from the repository or set WILTED_PIPELINE_PYTHONPATH"
                )
            }
        }
        let process = Process()
        process.executableURL = configuration.interpreterURL
        process.arguments = [configuration.workerURL.path]
        var environment = ProcessInfo.processInfo.environment
        if let pythonPath = configuration.pythonPath { environment["PYTHONPATH"] = pythonPath.path }
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PATH"] = configuration.workerPATH(inherited: environment["PATH"])
        process.environment = environment
        let exitObservation = ProcessExitObservation()
        process.terminationHandler = { child in
            exitObservation.record(terminationStatus: child.terminationStatus)
        }

        let input = Pipe(), output = Pipe(), errors = Pipe()
        // A worker that dies before reading its request leaves the write end
        // broken, and the default disposition for SIGPIPE would take this
        // process down with it. The write must fail as an error instead.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        let collector = WorkerOutputCollector(onProgress: onProgress)
        errors.fileHandleForReading.readabilityHandler = { collector.read($0, progress: true) }
        output.fileHandleForReading.readabilityHandler = { collector.read($0, progress: false) }
        defer {
            errors.fileHandleForReading.readabilityHandler = nil
            output.fileHandleForReading.readabilityHandler = nil
            collector.stopReading()
            // Stop/read synchronization prevents queued handlers touching a
            // closed descriptor, including failed launches and cancellation.
            for handle in [input.fileHandleForReading, input.fileHandleForWriting,
                           output.fileHandleForReading, output.fileHandleForWriting,
                           errors.fileHandleForReading, errors.fileHandleForWriting] {
                try? handle.close()
            }
        }
        do { try process.run() } catch {
            throw PodcastPreparationError.workerUnavailable(String(describing: error))
        }
        // The child owns its duplicated stdin reader now. Keeping this parent's
        // reader open would let a blocked writer wait forever after child exit.
        try? input.fileHandleForReading.close()
        // Off the calling task on purpose. A request carrying a published
        // transcript is larger than a pipe buffer, so a synchronous write
        // blocks until the worker drains it -- and a worker that dies first
        // would deadlock the caller before the timeout loop below ever starts.
        // A broken pipe is not reported here; the missing result is.
        let writer = Task.detached {
            let handle = input.fileHandleForWriting
            try? handle.write(contentsOf: request)
            try? handle.close()
        }
        defer { writer.cancel() }

        let processID = process.processIdentifier
        let deadline = Date().addingTimeInterval(configuration.timeout)
        var interrupted: PodcastPreparationError?
        while exitObservation.terminationStatus == nil {
            if Task.isCancelled {
                interrupted = .cancelled
                break
            }
            if Date() >= deadline {
                interrupted = .workerTimedOut
                break
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if let interrupted {
            try await terminateAndReap(process, exitObservation: exitObservation)
            await writer.value
            throw interrupted
        }
        guard let terminationStatus = exitObservation.terminationStatus else {
            throw PodcastPreparationError.workerFailed(
                code: "worker-cleanup", message: "owned worker exit was not observed"
            )
        }
        let wasReaped = await Task.detached {
            Self.waitForReapedProcess(processID, until: Date().addingTimeInterval(1))
        }.value
        guard wasReaped else {
            throw PodcastPreparationError.workerFailed(
                code: "worker-cleanup", message: "owned worker exited but was not reaped"
            )
        }
        await writer.value
        errors.fileHandleForReading.readabilityHandler = nil
        output.fileHandleForReading.readabilityHandler = nil
        collector.stopReading()
        // The handlers stop firing at exit with bytes possibly still buffered
        // in the pipe, so the tail is drained explicitly. Without this a fast
        // worker's entire result can be lost.
        collector.appendResult(output.fileHandleForReading.readDataToEndOfFile())
        collector.appendProgress(errors.fileHandleForReading.readDataToEndOfFile())
        collector.flushProgress()
        let result = collector.result()
        guard !result.isEmpty else {
            throw PodcastPreparationError.workerFailed(
                code: "no-output",
                message: "the worker exited with status \(terminationStatus) and produced no result"
            )
        }
        return result
    }

    /// Observe exit without `Process.waitUntilExit()`, which can wait forever
    /// while polling a run loop that is not being serviced by this async task.
    private func terminateAndReap(
        _ process: Process,
        exitObservation: ProcessExitObservation
    ) async throws {
        try await Task.detached {
            let pid = process.processIdentifier
            if process.isRunning { process.terminate() }
            let termDeadline = Date().addingTimeInterval(1)
            while exitObservation.terminationStatus == nil && Date() < termDeadline { usleep(20_000) }
            if process.isRunning && exitObservation.terminationStatus == nil { _ = kill(pid, SIGKILL) }
            let killDeadline = Date().addingTimeInterval(3)
            while exitObservation.terminationStatus == nil && Date() < killDeadline { usleep(20_000) }
            guard exitObservation.terminationStatus != nil,
                  Self.waitForReapedProcess(pid, until: Date().addingTimeInterval(1)) else {
                throw PodcastPreparationError.workerFailed(
                    code: "worker-cleanup", message: "owned worker did not exit after termination escalation"
                )
            }
        }.value
    }

    /// Foundation owns this child PID; ESRCH confirms its exit has been reaped.
    private static func waitForReapedProcess(_ pid: Int32, until deadline: Date) -> Bool {
        while Date() < deadline {
            let result = kill(pid, 0)
            let error = errno
            if result == -1 && error == ESRCH { return true }
            usleep(20_000)
        }
        let result = kill(pid, 0)
        return result == -1 && errno == ESRCH
    }
}

/// Receives Foundation's asynchronous termination observation without making
/// an async caller block on Process.waitUntilExit()'s current run loop.
private final class ProcessExitObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?

    var terminationStatus: Int32? {
        lock.lock(); defer { lock.unlock() }
        return status
    }

    func record(terminationStatus: Int32) {
        lock.lock(); defer { lock.unlock() }
        status = terminationStatus
    }
}

/// Buffers a worker's two output streams from their read handlers.
///
/// The handlers fire on an arbitrary queue, so every access is behind one lock
/// rather than relying on the caller's isolation.
private final class WorkerOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let readLock = NSLock()
    private var reading = true
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private let onProgress: @Sendable (PodcastPreparationProgress) -> Void

    init(onProgress: @escaping @Sendable (PodcastPreparationProgress) -> Void) {
        self.onProgress = onProgress
    }

    /// Serialize descriptor reads with shutdown; queued handlers become no-ops.
    func read(_ handle: FileHandle, progress: Bool) {
        readLock.lock(); defer { readLock.unlock() }
        guard reading else { return }
        let data = handle.availableData
        guard !data.isEmpty else {
            handle.readabilityHandler = nil
            return
        }
        if progress { appendProgress(data) } else { appendResult(data) }
    }

    func stopReading() {
        readLock.lock(); defer { readLock.unlock() }
        reading = false
    }

    func appendResult(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock(); stdoutBuffer.append(data); lock.unlock()
    }

    func appendProgress(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        stderrBuffer.append(data)
        var lines: [Data] = []
        while let newline = stderrBuffer.firstIndex(of: 0x0A) {
            lines.append(stderrBuffer[stderrBuffer.startIndex..<newline])
            stderrBuffer = stderrBuffer[stderrBuffer.index(after: newline)...]
        }
        lock.unlock()
        lines.forEach(emit)
    }

    /// A worker that dies mid-line still has something to say, so the partial
    /// tail is offered once at the end rather than discarded.
    func flushProgress() {
        lock.lock()
        let tail = stderrBuffer
        stderrBuffer = Data()
        lock.unlock()
        emit(tail)
    }

    func result() -> Data {
        lock.lock(); defer { lock.unlock() }
        return stdoutBuffer
    }

    private func emit(_ line: Data) {
        guard !line.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let stage = object["stage"] as? String else { return }
        onProgress(PodcastPreparationProgress(stage: stage,
                                              detail: object["detail"] as? String ?? "",
                                              fraction: object["fraction"] as? Double,
                                              requestID: (object["requestID"] as? String).flatMap(UUID.init(uuidString:))))
    }
}
