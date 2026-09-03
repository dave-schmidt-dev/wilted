import CryptoKit
import Foundation
import WiltedDomain

public enum PodcastPreparationError: Error, Equatable, LocalizedError, Sendable {
    case episodeNotDownloaded
    case workerUnavailable(String)
    case workerFailed(code: String, message: String)
    case workerTimedOut
    case malformedWorkerResponse(String)
    case preparedAudioUnreadable
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .episodeNotDownloaded: "Download the episode before preparing it."
        case .workerUnavailable: "Wilted could not start the preparation pipeline."
        case .workerFailed(_, let message): "Preparation failed: \(message)"
        case .workerTimedOut: "Preparation took too long and was stopped."
        case .malformedWorkerResponse: "The preparation pipeline returned an unreadable result."
        case .preparedAudioUnreadable: "The prepared audio could not be read back."
        case .cancelled: "Preparation was cancelled."
        }
    }
}

/// One advertisement the pipeline found, in the downloaded audio's own clock.
///
/// Kept for the report rather than for playback: once the audio is cut these
/// spans no longer exist in the file, and their value is telling the owner what
/// was removed and how confident the classifier was.
public struct PodcastAdSegment: Equatable, Sendable {
    public let startSeconds: Double
    public let endSeconds: Double
    public let label: String
    public let confidence: Double

    public var durationSeconds: Double { max(0, endSeconds - startSeconds) }
}

/// One span of the original audio that survived the cut, and where it landed.
///
/// Carried back from the worker so a listener's saved position can move onto
/// the prepared file rather than being discarded with the revision it belonged
/// to. Estimating from total removed time would be wrong: what matters is how
/// much was removed *before* the position, not in total.
public struct PodcastKeepInterval: Equatable, Sendable {
    public let startSeconds: Double
    public let endSeconds: Double
    public let outputStartSeconds: Double

    /// Where `seconds` on the original clock lands on the cut clock, or nil if
    /// it fell inside a removed span.
    static func map(_ seconds: Double, through intervals: [PodcastKeepInterval]) -> Double? {
        guard !intervals.isEmpty else { return nil }
        for interval in intervals where seconds >= interval.startSeconds && seconds < interval.endSeconds {
            return interval.outputStartSeconds + (seconds - interval.startSeconds)
        }
        // Past the end of the last surviving span: the listener had finished
        // everything that remains, so the end of the file is the honest answer.
        if let last = intervals.last, seconds >= last.endSeconds {
            return last.outputStartSeconds + (last.endSeconds - last.startSeconds)
        }
        return nil
    }
}

public struct PodcastPreparationProgress: Equatable, Sendable {
    public let stage: String
    public let detail: String
    public let fraction: Double?
    public let evidence: PreparationEvidence?

    public init(stage: String, detail: String = "", fraction: Double? = nil, evidence: PreparationEvidence? = nil) {
        self.stage = stage
        self.detail = detail
        self.fraction = fraction
        self.evidence = evidence
    }
}

extension PodcastPreparationProgress {
    /// Where this stage belongs in the journal the Processor page reads.
    ///
    /// The worker's vocabulary is its own -- it names transcript tiers and
    /// ffmpeg passes -- but the durable record has one shape for every kind of
    /// preparation, so a reader does not need to know which pipeline ran.
    var journalStage: PreparationStage {
        let parts = stage.split(separator: ".").map(String.init)
        switch (parts.first ?? stage, parts.count > 1 ? parts[1] : "") {
        case ("transcript", "published"): return .fetching
        case ("transcript", _): return .extracting
        case ("ads", _): return .assembling
        case ("audio", _): return .saving
        default: return .preparing
        }
    }
}

public struct PodcastPreparationResult: Sendable {
    public let revision: AudioRevision
    public let mediaURL: URL
    public let transcript: Transcript
    public let adSegments: [PodcastAdSegment]
    public let removedSeconds: Double
    public var audioWasCut: Bool { removedSeconds > 0 }

    /// What the run did, for the row: "Ready · 5 ads removed (7:22) ·
    /// transcript synced". Leads with the completion state and then names
    /// each step's result, so a reader can see the run finished and where
    /// it fell short ("transcript not synced") without knowing the
    /// pipeline. Journalled as the run's terminal detail so the answer
    /// outlives the process that knew it.
    public var summary: String {
        Self.summary(advertisements: adSegments.count, secondsRemoved: removedSeconds, timing: transcript.timing)
    }

    public static let readyLabel = "Ready"

    public static func summary(advertisements: Int, secondsRemoved: Double, timing: TranscriptTiming) -> String {
        var parts: [String] = [readyLabel]
        if advertisements > 0, secondsRemoved > 0 {
            let removed = clock(secondsRemoved)
            parts.append(advertisements == 1 ? "1 ad removed (\(removed))" : "\(advertisements) ads removed (\(removed))")
        } else {
            parts.append("no ads found")
        }
        parts.append(transcriptStep(timing))
        return parts.joined(separator: " · ")
    }

    public static func transcriptStep(_ timing: TranscriptTiming) -> String {
        switch timing {
        case .published: "transcript synced from the feed"
        case .aligned: "transcript synced"
        case .none: "transcript not synced"
        }
    }

    /// `h:mm:ss` at an hour or more, `m:ss` below it.
    static func clock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0).rounded())
        let (hours, minutes, secs) = (total / 3600, (total % 3600) / 60, total % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }
}

/// The seam between the coordinator and the Python process.
///
/// Exists so the gate can exercise every decision this file makes without a
/// virtualenv, a four-gigabyte language model, or a GPU. The real runner is the
/// only part that needs any of those.
public protocol PodcastPipelineRunning: Sendable {
    func run(
        request: Data,
        onProgress: @escaping @Sendable (PodcastPreparationProgress) -> Void
    ) async throws -> Data
}

/// Runs the pipeline worker as a subprocess.
///
/// The worker is Python because the ad detection it wraps is Python: about
/// 1,500 lines of tuned prompts and boundary verification that would lose its
/// tuning in translation. Paths are configuration rather than constants --
/// the previous project is a working tree on this machine, not a dependency
/// this app ships.
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
            let previousProject = home.appending(path: "Documents/Projects/wilted-old")
            let interpreter = environment["WILTED_PIPELINE_PYTHON"].map { URL(fileURLWithPath: $0) }
                ?? previousProject.appending(path: ".venv/bin/python")
            let worker = environment["WILTED_PIPELINE_WORKER"].map { URL(fileURLWithPath: $0) }
                ?? home.appending(path: "Documents/Projects/wilted/Producer/Workers/wilted_pipeline.py")
            let sources = environment["WILTED_PIPELINE_PYTHONPATH"].map { URL(fileURLWithPath: $0) }
                ?? previousProject.appending(path: "src")
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
            throw PodcastPreparationError.workerUnavailable("no interpreter at \(configuration.interpreterURL.path)")
        }
        guard fileManager.fileExists(atPath: configuration.workerURL.path) else {
            throw PodcastPreparationError.workerUnavailable("no worker at \(configuration.workerURL.path)")
        }
        let process = Process()
        process.executableURL = configuration.interpreterURL
        process.arguments = [configuration.workerURL.path]
        var environment = ProcessInfo.processInfo.environment
        if let pythonPath = configuration.pythonPath { environment["PYTHONPATH"] = pythonPath.path }
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PATH"] = configuration.workerPATH(inherited: environment["PATH"])
        process.environment = environment

        let input = Pipe(), output = Pipe(), errors = Pipe()
        // A worker that dies before reading its request leaves the write end
        // broken, and the default disposition for SIGPIPE would take this
        // process down with it. The write must fail as an error instead.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        let collector = WorkerOutputCollector(onProgress: onProgress)
        errors.fileHandleForReading.readabilityHandler = { handle in
            collector.appendProgress(handle.availableData)
        }
        output.fileHandleForReading.readabilityHandler = { handle in
            collector.appendResult(handle.availableData)
        }
        do { try process.run() } catch {
            throw PodcastPreparationError.workerUnavailable(String(describing: error))
        }
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

        let deadline = Date().addingTimeInterval(configuration.timeout)
        defer {
            errors.fileHandleForReading.readabilityHandler = nil
            output.fileHandleForReading.readabilityHandler = nil
        }
        while process.isRunning {
            if Task.isCancelled {
                process.terminate()
                throw PodcastPreparationError.cancelled
            }
            if Date() >= deadline {
                process.terminate()
                throw PodcastPreparationError.workerTimedOut
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
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
                message: "the worker exited with status \(process.terminationStatus) and produced no result"
            )
        }
        return result
    }
}

/// Tracks the journal writes one run has started.
///
/// A progress callback must never block the worker, so each write is enqueued
/// rather than awaited where it is reported. Recording them synchronously here
/// means the run can drain the exact set before announcing its outcome, so the
/// journal a reader sees afterwards is complete rather than still arriving.
private final class JournalWrites: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [Task<Void, Never>] = []
    private var nextOrdinal = 0

    func eventID(for stage: String) -> String {
        lock.lock(); defer { lock.unlock() }
        nextOrdinal += 1
        return "\(stage)#\(nextOrdinal)"
    }

    func track(_ write: Task<Void, Never>) {
        lock.lock(); pending.append(write); lock.unlock()
    }

    func drain() async {
        for write in take() { await write.value }
    }

    private func take() -> [Task<Void, Never>] {
        lock.lock(); defer { lock.unlock() }
        let writes = pending
        pending = []
        return writes
    }
}

/// Buffers a worker's two output streams from their read handlers.
///
/// The handlers fire on an arbitrary queue, so every access is behind one lock
/// rather than relying on the caller's isolation.
private final class WorkerOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private let onProgress: @Sendable (PodcastPreparationProgress) -> Void

    init(onProgress: @escaping @Sendable (PodcastPreparationProgress) -> Void) {
        self.onProgress = onProgress
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
                                              fraction: object["fraction"] as? Double))
    }
}

/// Turns a downloaded episode into a prepared one: a transcript with real
/// timing, and audio with the advertisements removed.
///
/// Ordering is not arbitrary. Ads are found in the transcript, so the
/// transcript has to exist first; and cutting the audio invalidates every
/// timestamp after the first cut, so the cues are remapped onto the new file
/// before anything is stored. The revision identity follows the bytes: cut
/// audio is different audio, so it earns a new `RevisionID` and the transcript
/// binds to that one.
public actor PodcastPreparationPipeline {
    /// A published transcript larger than this is not a transcript.
    public static let maximumTranscriptDocumentBytes = 8 * 1_024 * 1_024

    private let store: LocalLibraryStore
    private let runner: any PodcastPipelineRunning
    private let documentLoader: any PodcastFeedLoading
    private let workDirectory: URL
    private let removeAds: Bool
    private let allowSpeechToText: Bool
    private let now: @Sendable () -> Date

    public init(
        store: LocalLibraryStore,
        workDirectory: URL,
        runner: any PodcastPipelineRunning = SubprocessPodcastPipelineRunner(),
        documentLoader: any PodcastFeedLoading = URLSessionPodcastFeedLoader(),
        removeAds: Bool = true,
        allowSpeechToText: Bool = true,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.runner = runner
        self.documentLoader = documentLoader
        self.workDirectory = workDirectory
        self.removeAds = removeAds
        self.allowSpeechToText = allowSpeechToText
        self.now = now
    }

    /// The journal key for one episode's preparation history.
    public static func requestID(for episodeID: ItemID) -> String { "podcast-prepare|" + episodeID.rawValue }

    public func prepare(
        episodeID: ItemID,
        onStatus: @escaping @Sendable (PodcastPreparationProgress) -> Void = { _ in }
    ) async throws -> PodcastPreparationResult {
        let requestID = Self.requestID(for: episodeID)
        // The journal is one attempt deep. Left in place, the previous
        // attempt's terminal row would report this one as finished before it
        // had started, and its stale stage rows would read as this run's.
        try? await store.clearPreparationJournal(for: requestID)
        let writes = JournalWrites()
        // Every status is journalled as well as reported, so a run that failed
        // while the window was closed still leaves evidence a reader can find.
        // Journalling must never be the thing that fails a preparation.
        let clock = now
        let report: @Sendable (PodcastPreparationProgress) -> Void = { [weak self] progress in
            onStatus(progress)
            guard let self else { return }
            // Stamped here rather than inside the journal task: the write is
            // enqueued behind this actor and may not run until the run is
            // over, and an entry timestamped then would sort after the
            // terminal record it preceded.
            let emittedAt = Timestamp(clock())
            let eventID = writes.eventID(for: progress.stage)
            writes.track(Task { await self.journal(progress, eventID: eventID, at: emittedAt, for: episodeID, requestID: requestID) })
        }

        guard let episode = try await store.podcastEpisode(for: episodeID),
              let download = try await store.download(for: episodeID), download.status == .completed,
              let audioURL = download.localURL,
              FileManager.default.fileExists(atPath: audioURL.path),
              let stored = try await store.readyRevision(for: episodeID) else {
            await journalTerminal(episodeID: episodeID, requestID: requestID,
                                  error: PodcastPreparationError.episodeNotDownloaded, revisionID: nil)
            throw PodcastPreparationError.episodeNotDownloaded
        }

        report(PodcastPreparationProgress(stage: "pipeline.start", detail: episode.title))
        do {
            var request: [String: Any] = [
                "protocolVersion": 1,
                "audioPath": audioURL.path,
                "outputPath": preparedAudioURL(for: audioURL).path,
                "workDir": workDirectory.path,
                "removeAds": removeAds,
                "allowSpeechToText": allowSpeechToText,
            ]
            if let published = await fetchPublishedTranscript(for: episode, onStatus: report) {
                request["publishedTranscript"] = published
            }
            // The feed's show notes name the hosts, guests, stories, products,
            // and sponsors: the worker's glossary for the words speech-to-text
            // got wrong.
            if let notes = episode.notes {
                request["episodeNotes"] = notes
            }
            request["episodeTitle"] = episode.title
            let response = try await runner.run(request: try JSONSerialization.data(withJSONObject: request),
                                                onProgress: report)
            let payload = try Self.decode(response)
            report(Self.resultProgress(payload))
            for (index, ad) in payload.adSegments.enumerated() { report(Self.adProgress(ad, ordinal: index + 1)) }
            let result = try await commit(payload, episode: episode, download: download,
                                          downloadedRevision: stored.revision, audioURL: audioURL, onStatus: report)
            await writes.drain()
            await journalTerminal(episodeID: episodeID, requestID: requestID, error: nil,
                                  revisionID: result.revision.revisionID, summary: result.summary)
            return result
        } catch {
            await writes.drain()
            await journalTerminal(episodeID: episodeID, requestID: requestID, error: error, revisionID: nil)
            throw error
        }
    }

    // MARK: Journal

    private func journal(
        _ progress: PodcastPreparationProgress, eventID: String, at emittedAt: Timestamp,
        for episodeID: ItemID, requestID: String
    ) async {
        let detail = progress.detail.isEmpty ? progress.stage : progress.detail
        guard let status = try? PreparationStatus(
            stage: progress.journalStage, detail: String(detail.prefix(1_024)),
            fraction: progress.fraction, cancellable: true, emittedAt: emittedAt, evidence: progress.evidence
        ) else { return }
        try? await store.record(preparation: PreparationJournalEntry(
            id: requestID + "|" + eventID, itemID: episodeID, requestID: requestID, status: status
        ))
    }

    private func journalTerminal(
        episodeID: ItemID, requestID: String, error: (any Error)?, revisionID: RevisionID?,
        summary: String? = nil
    ) async {
        let outcome: PreparationOutcome
        let producerError: ProducerError?
        if error == nil {
            outcome = .succeeded
            producerError = nil
        } else if error is CancellationError || (error as? PodcastPreparationError) == .cancelled {
            outcome = .cancelled
            producerError = nil
        } else {
            outcome = .failed
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error!)
            producerError = try? ProducerError(code: Self.errorCode(for: error!),
                                               message: String(message.prefix(1_024)), retryable: true,
                                               stage: "podcast-preparation")
        }
        guard outcome != .failed || producerError != nil,
              let terminal = try? PreparationTerminalResult(outcome: outcome, revisionID: revisionID,
                                                            error: producerError),
              let status = try? PreparationStatus(
                stage: outcome == .succeeded ? .completed : (outcome == .cancelled ? .cancelled : .failed),
                detail: producerError?.message ?? (outcome == .succeeded ? (summary ?? "Prepared.") : "Cancelled."),
                cancellable: false, terminalResult: terminal, emittedAt: Timestamp(now())
              ) else { return }
        try? await store.record(preparation: PreparationJournalEntry(
            id: requestID + "|terminal", itemID: episodeID, requestID: requestID, status: status
        ))
    }

    private static func errorCode(for error: any Error) -> ProducerErrorCode {
        switch error as? PodcastPreparationError {
        case .episodeNotDownloaded: .invalidRequest
        case .workerUnavailable: .unsupported
        case .workerTimedOut: .timedOut
        case .malformedWorkerResponse: .protocolMismatch
        case .preparedAudioUnreadable: .outputInvalid
        case .cancelled: .cancelled
        default: .failed
        }
    }

    // MARK: Published transcript

    /// Fetches the feed's own timed transcript, if it publishes one.
    ///
    /// The fetch happens here rather than in the worker so the transport policy
    /// stays in one place: HTTPS only, bounded, and never handing a credentialed
    /// feed's URL to a second process. A failure is not an error -- it means the
    /// pipeline falls through to speech-to-text, which is the tier below it.
    private func fetchPublishedTranscript(
        for episode: PodcastEpisode,
        onStatus: @escaping @Sendable (PodcastPreparationProgress) -> Void
    ) async -> [String: Any]? {
        guard let source = episode.timedTranscriptSource else { return nil }
        onStatus(PodcastPreparationProgress(stage: "transcript.published.fetch", detail: source.mediaType))
        do {
            let response = try await documentLoader.load(source.url, maximumBytes: Self.maximumTranscriptDocumentBytes)
            guard (200..<300).contains(response.statusCode),
                  let body = String(data: response.data, encoding: .utf8) ?? String(data: response.data, encoding: .isoLatin1) else {
                onStatus(PodcastPreparationProgress(stage: "transcript.published.unreadable",
                                                    detail: "status \(response.statusCode)"))
                return nil
            }
            var published: [String: Any] = ["url": source.url.absoluteString,
                                            "mediaType": source.mediaType,
                                            "body": body]
            if let language = source.languageCode { published["languageCode"] = language }
            return published
        } catch {
            onStatus(PodcastPreparationProgress(stage: "transcript.published.unreachable",
                                                detail: String(describing: error)))
            return nil
        }
    }

    // MARK: Worker response

    struct WorkerPayload: Sendable {
        var timing: TranscriptTiming
        var cues: [TranscriptCue]
        var text: String?
        var languageCode: String?
        var audioPath: String
        var audioChanged: Bool
        var durationSeconds: Double?
        var adSegments: [PodcastAdSegment]
        var removedSeconds: Double
        var keepIntervals: [PodcastKeepInterval]
    }

    static func decode(_ data: Data) throws -> WorkerPayload {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PodcastPreparationError.malformedWorkerResponse("result was not a JSON object")
        }
        if object["ok"] as? Bool != true {
            throw PodcastPreparationError.workerFailed(code: object["code"] as? String ?? "unknown",
                                                       message: object["message"] as? String ?? "no message")
        }
        guard let audioPath = object["audioPath"] as? String, !audioPath.isEmpty else {
            throw PodcastPreparationError.malformedWorkerResponse("no audioPath")
        }
        guard let timing = TranscriptTiming(rawValue: object["timing"] as? String ?? "none") else {
            throw PodcastPreparationError.malformedWorkerResponse("unknown timing")
        }
        var cues: [TranscriptCue] = []
        for raw in object["cues"] as? [[String: Any]] ?? [] {
            guard let start = raw["startSeconds"] as? Double, let end = raw["endSeconds"] as? Double,
                  let text = raw["text"] as? String else {
                throw PodcastPreparationError.malformedWorkerResponse("malformed cue")
            }
            guard let cue = try? TranscriptCue(startSeconds: start, endSeconds: end, text: text) else { continue }
            cues.append(cue)
        }
        let ads = (object["adSegments"] as? [[String: Any]] ?? []).compactMap { raw -> PodcastAdSegment? in
            guard let start = raw["startSeconds"] as? Double, let end = raw["endSeconds"] as? Double,
                  let label = raw["label"] as? String else { return nil }
            return PodcastAdSegment(startSeconds: start, endSeconds: end, label: label,
                                    confidence: raw["confidence"] as? Double ?? 0)
        }
        return WorkerPayload(
            timing: cues.isEmpty ? .none : timing,
            cues: cues,
            text: object["text"] as? String,
            languageCode: object["languageCode"] as? String,
            audioPath: audioPath,
            audioChanged: object["audioChanged"] as? Bool ?? false,
            durationSeconds: (object["durationSeconds"] as? Double).flatMap { $0 > 0 ? $0 : nil },
            adSegments: ads,
            removedSeconds: object["removedSeconds"] as? Double ?? 0,
            keepIntervals: (object["keepIntervals"] as? [[String: Any]] ?? []).compactMap { raw in
                guard let start = raw["startSeconds"] as? Double, let end = raw["endSeconds"] as? Double,
                      let output = raw["outputStartSeconds"] as? Double, end > start else { return nil }
                return PodcastKeepInterval(startSeconds: start, endSeconds: end, outputStartSeconds: output)
            }
        )
    }

    // MARK: Commit

    private func commit(
        _ payload: WorkerPayload,
        episode: PodcastEpisode,
        download: PodcastDownload,
        downloadedRevision: AudioRevision,
        audioURL: URL,
        onStatus: @escaping @Sendable (PodcastPreparationProgress) -> Void
    ) async throws -> PodcastPreparationResult {
        guard payload.audioChanged else {
            let transcript = try Self.transcript(from: payload, itemID: episode.itemID,
                                                 revisionID: downloadedRevision.revisionID,
                                                 updatedAt: Timestamp(now()))
            try await store.saveReadyRevision(downloadedRevision, mediaURL: audioURL, transcript: transcript)
            return finish(payload, revision: downloadedRevision, mediaURL: audioURL,
                          transcript: transcript, onStatus: onStatus)
        }

        onStatus(PodcastPreparationProgress(stage: "audio.publish", detail: "storing prepared audio"))
        let preparedURL = URL(fileURLWithPath: payload.audioPath)
        guard FileManager.default.fileExists(atPath: preparedURL.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: preparedURL.path),
              let byteCount = attributes[.size] as? Int64, byteCount > 0 else {
            throw PodcastPreparationError.preparedAudioUnreadable
        }
        let hash = try Self.contentHash(of: preparedURL)
        let revisionID = try await store.resolvePodcastRevision(
            itemID: episode.itemID,
            contentHash: hash
        )
        // Prefer what the worker measured on the cut file; fall back to
        // subtraction only when the probe could not run.
        let duration = payload.durationSeconds
            ?? max(0.001, downloadedRevision.durationSeconds - payload.removedSeconds)
        let finalURL = try await store.readyRevision(for: episode.itemID, revisionID: revisionID)?.mediaURL
            ?? audioURL.deletingLastPathComponent()
                .appendingPathComponent(revisionID.rawValue + "." + audioURL.pathExtension)
        if finalURL != preparedURL {
            if FileManager.default.fileExists(atPath: finalURL.path) {
                guard try Self.contentHash(of: finalURL) == hash else {
                    throw PodcastPreparationError.preparedAudioUnreadable
                }
                try FileManager.default.removeItem(at: preparedURL)
            } else {
                try FileManager.default.moveItem(at: preparedURL, to: finalURL)
            }
        }
        let revision = try AudioRevision(itemID: episode.itemID, revisionID: revisionID,
                                         durationSeconds: duration, byteCount: byteCount,
                                         contentHash: hash, mediaType: downloadedRevision.mediaType,
                                         createdAt: Timestamp(now()), schemaVersion: 3)
        let prepared = try PodcastDownload(episodeID: episode.itemID, status: .completed,
                                           bytesReceived: byteCount, expectedByteCount: byteCount,
                                           localURL: finalURL, contentHash: hash,
                                           updatedAt: Timestamp(now()))
        let transcript = try Self.transcript(from: payload, itemID: episode.itemID, revisionID: revisionID,
                                             updatedAt: Timestamp(now()))
        let carried = try await carriedPlayback(from: downloadedRevision, to: revision,
                                                keeps: payload.keepIntervals, duration: duration)

        try await store.replaceReadyRevision(revision, mediaURL: finalURL, transcript: transcript,
                                             download: prepared, superseding: downloadedRevision.revisionID,
                                             carrying: carried)
        // Only now is the original safe to remove. The store no longer refers
        // to it, and until that save committed a failure here would have left
        // an episode whose audio was deleted and unrecoverable without
        // downloading it again.
        if audioURL != finalURL { try? FileManager.default.removeItem(at: audioURL) }
        return finish(payload, revision: revision, mediaURL: finalURL, transcript: transcript, onStatus: onStatus)
    }

    /// Moves a saved listening position onto the prepared audio.
    ///
    /// A position inside a removed advertisement has nowhere to land, so it is
    /// dropped rather than guessed at; anything else keeps its place in the
    /// content the listener was actually hearing.
    private func carriedPlayback(
        from previous: AudioRevision,
        to revision: AudioRevision,
        keeps: [PodcastKeepInterval],
        duration: Double
    ) async throws -> PlaybackState? {
        guard let existing = try await store.playbackState(for: previous.itemID, revisionID: previous.revisionID),
              let mapped = PodcastKeepInterval.map(existing.positionSeconds, through: keeps) else { return nil }
        return try PlaybackState(
            itemID: revision.itemID, revisionID: revision.revisionID, sessionID: existing.sessionID,
            sequence: existing.sequence + 1, positionSeconds: min(mapped, duration),
            durationSeconds: duration, completed: existing.completed, intent: existing.intent,
            deviceID: existing.deviceID, updatedAt: Timestamp(now())
        )
    }

    private func finish(
        _ payload: WorkerPayload,
        revision: AudioRevision,
        mediaURL: URL,
        transcript: Transcript,
        onStatus: @escaping @Sendable (PodcastPreparationProgress) -> Void
    ) -> PodcastPreparationResult {
        onStatus(PodcastPreparationProgress(
            stage: "pipeline.complete",
            detail: "\(payload.adSegments.count) advertisements, \(payload.cues.count) cues",
            fraction: 1
        ))
        return PodcastPreparationResult(revision: revision, mediaURL: mediaURL, transcript: transcript,
                                        adSegments: payload.adSegments, removedSeconds: payload.removedSeconds)
    }

    private static func resultProgress(_ payload: WorkerPayload) -> PodcastPreparationProgress {
        let evidence = try? PreparationEvidence(kind: "worker-result", fields: [
            "audioChanged": payload.audioChanged ? "true" : "false",
            "advertisements": String(payload.adSegments.count),
            "removedSeconds": String(format: "%.3f", payload.removedSeconds),
            "cues": String(payload.cues.count), "timing": payload.timing.rawValue
        ])
        return PodcastPreparationProgress(stage: "pipeline.result",
                                          detail: "audio \(payload.audioChanged ? "changed" : "unchanged") · \(payload.adSegments.count) ads · \(payload.cues.count) cues",
                                          evidence: evidence)
    }

    static func adProgress(_ ad: PodcastAdSegment, ordinal: Int) -> PodcastPreparationProgress {
        func clock(_ seconds: Double) -> String {
            // The worker result is external input. Do not trap while trying to
            // narrate a malformed timestamp in its durable audit record.
            guard seconds.isFinite, seconds >= 0, seconds <= 7 * 24 * 60 * 60 else { return "unknown" }
            let total = Int(seconds.rounded())
            return String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
        }
        // Worker labels are external input. Keep the evidence valid and the
        // user-facing detail useful when a malformed label is unexpectedly long.
        let label: String
        if ad.label.isEmpty {
            label = "unknown label"
        } else if ad.label.count > 256 {
            label = String(ad.label.prefix(253)) + "..."
        } else {
            label = ad.label
        }
        let evidence = try? PreparationEvidence(kind: "advertisement", fields: [
            "ordinal": String(ordinal), "startSeconds": String(format: "%.3f", ad.startSeconds),
            "endSeconds": String(format: "%.3f", ad.endSeconds), "label": label,
            "confidence": String(format: "%.4f", ad.confidence)
        ])
        let confidence: String
        if ad.confidence.isFinite, (0...1).contains(ad.confidence) {
            confidence = "\(Int((ad.confidence * 100).rounded()))%"
        } else {
            confidence = "unknown confidence"
        }
        return PodcastPreparationProgress(stage: "ads.detect.span.\(ordinal)",
                                          detail: "\(clock(ad.startSeconds))–\(clock(ad.endSeconds)) · \(label) · \(confidence)",
                                          evidence: evidence)
    }

    /// Builds the durable transcript, degrading rather than failing.
    ///
    /// An episode whose transcript is too large to carry is still a prepared
    /// episode with its advertisements removed; recording `oversized` says so
    /// truthfully, where throwing would discard the audio work as well.
    static func transcript(
        from payload: WorkerPayload,
        itemID: ItemID,
        revisionID: RevisionID,
        updatedAt: Timestamp
    ) throws -> Transcript {
        func unavailable(_ availability: TranscriptAvailability) throws -> Transcript {
            try Transcript(itemID: itemID, revisionID: revisionID, availability: availability,
                           languageCode: payload.languageCode, updatedAt: updatedAt)
        }
        guard let text = payload.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return try unavailable(.absent)
        }
        guard text.utf8.count <= Transcript.maximumTextUTF8Bytes else { return try unavailable(.oversized) }
        let cues = payload.cues.isEmpty ? nil : payload.cues
        do {
            return try Transcript(itemID: itemID, revisionID: revisionID, availability: .available,
                                  text: text, languageCode: payload.languageCode,
                                  timing: cues == nil ? .none : payload.timing, cues: cues,
                                  updatedAt: updatedAt)
        } catch {
            // The text fits and the cues do not. Keeping the words and dropping
            // the timing is strictly better than keeping neither.
            return try Transcript(itemID: itemID, revisionID: revisionID, availability: .available,
                                  text: text, languageCode: payload.languageCode, updatedAt: updatedAt)
        }
    }

    private func preparedAudioURL(for audioURL: URL) -> URL {
        workDirectory.appendingPathComponent("prepared-" + audioURL.lastPathComponent)
    }

    private static func contentHash(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_024 * 1_024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return "sha256:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
