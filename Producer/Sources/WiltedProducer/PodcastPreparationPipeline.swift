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

public struct PodcastPreparationProgress: Equatable, Sendable {
    public let stage: String
    public let detail: String
    public let fraction: Double?

    public init(stage: String, detail: String = "", fraction: Double? = nil) {
        self.stage = stage
        self.detail = detail
        self.fraction = fraction
    }
}

public struct PodcastPreparationResult: Sendable {
    public let revision: AudioRevision
    public let mediaURL: URL
    public let transcript: Transcript
    public let adSegments: [PodcastAdSegment]
    public let removedSeconds: Double
    public var audioWasCut: Bool { removedSeconds > 0 }
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

        public init(interpreterURL: URL, workerURL: URL, pythonPath: URL? = nil, timeout: TimeInterval = 7_200) {
            self.interpreterURL = interpreterURL
            self.workerURL = workerURL
            self.pythonPath = pythonPath
            self.timeout = timeout
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
            return Configuration(interpreterURL: interpreter, workerURL: worker,
                                 pythonPath: sources, timeout: timeout)
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
        process.environment = environment

        let input = Pipe(), output = Pipe(), errors = Pipe()
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
        input.fileHandleForWriting.write(request)
        try? input.fileHandleForWriting.close()

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

    public func prepare(
        episodeID: ItemID,
        onStatus: @escaping @Sendable (PodcastPreparationProgress) -> Void = { _ in }
    ) async throws -> PodcastPreparationResult {
        guard let episode = try await store.podcastEpisode(for: episodeID),
              let download = try await store.download(for: episodeID), download.status == .completed,
              let audioURL = download.localURL,
              FileManager.default.fileExists(atPath: audioURL.path),
              let stored = try await store.readyRevision(for: episodeID) else {
            throw PodcastPreparationError.episodeNotDownloaded
        }

        onStatus(PodcastPreparationProgress(stage: "pipeline.start", detail: episode.title))
        var request: [String: Any] = [
            "protocolVersion": 1,
            "audioPath": audioURL.path,
            "outputPath": preparedAudioURL(for: audioURL).path,
            "workDir": workDirectory.path,
            "removeAds": removeAds,
            "allowSpeechToText": allowSpeechToText,
        ]
        if let published = await fetchPublishedTranscript(for: episode, onStatus: onStatus) {
            request["publishedTranscript"] = published
        }

        let response = try await runner.run(request: try JSONSerialization.data(withJSONObject: request),
                                            onProgress: onStatus)
        let payload = try Self.decode(response)
        return try await commit(payload, episode: episode, download: download,
                                downloadedRevision: stored.revision, audioURL: audioURL, onStatus: onStatus)
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
            removedSeconds: object["removedSeconds"] as? Double ?? 0
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
        var revision = downloadedRevision
        var mediaURL = audioURL
        var savedDownload = download

        if payload.audioChanged {
            onStatus(PodcastPreparationProgress(stage: "audio.publish", detail: "storing prepared audio"))
            let preparedURL = URL(fileURLWithPath: payload.audioPath)
            guard FileManager.default.fileExists(atPath: preparedURL.path),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: preparedURL.path),
                  let byteCount = attributes[.size] as? Int64, byteCount > 0 else {
                throw PodcastPreparationError.preparedAudioUnreadable
            }
            let hash = try Self.contentHash(of: preparedURL)
            let revisionID = try RevisionID.derive(downloadedAudioContentHash: hash)
            // Prefer what the worker measured on the cut file; fall back to
            // subtraction only when the probe could not run.
            let duration = payload.durationSeconds
                ?? max(0.001, downloadedRevision.durationSeconds - payload.removedSeconds)
            let finalURL = audioURL.deletingLastPathComponent()
                .appendingPathComponent(revisionID.rawValue + "." + audioURL.pathExtension)
            if finalURL != preparedURL {
                try? FileManager.default.removeItem(at: finalURL)
                try FileManager.default.moveItem(at: preparedURL, to: finalURL)
            }
            revision = try AudioRevision(itemID: episode.itemID, revisionID: revisionID,
                                         durationSeconds: duration, byteCount: byteCount,
                                         contentHash: hash, mediaType: downloadedRevision.mediaType,
                                         createdAt: Timestamp(now()), schemaVersion: 3)
            savedDownload = try PodcastDownload(episodeID: episode.itemID, status: .completed,
                                                bytesReceived: byteCount, expectedByteCount: byteCount,
                                                localURL: finalURL, contentHash: hash,
                                                updatedAt: Timestamp(now()))
            mediaURL = finalURL
            // The uncut download is superseded, not history. Keeping it would
            // double the disk cost of every prepared episode for a file nothing
            // can reach: playback follows the ready revision, and that is now
            // the cut one.
            if audioURL != finalURL { try? FileManager.default.removeItem(at: audioURL) }
        }

        let transcript = try Self.transcript(from: payload, itemID: episode.itemID, revisionID: revision.revisionID,
                                             updatedAt: Timestamp(now()))
        if payload.audioChanged {
            try await store.finalizePodcastDownload(revision: revision, mediaURL: mediaURL, download: savedDownload)
        }
        try await store.saveReadyRevision(revision, mediaURL: mediaURL, transcript: transcript)
        onStatus(PodcastPreparationProgress(stage: "pipeline.complete",
                                            detail: "\(payload.adSegments.count) advertisements, \(payload.cues.count) cues",
                                            fraction: 1))
        return PodcastPreparationResult(revision: revision, mediaURL: mediaURL, transcript: transcript,
                                        adSegments: payload.adSegments, removedSeconds: payload.removedSeconds)
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
