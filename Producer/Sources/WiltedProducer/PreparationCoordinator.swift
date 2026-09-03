import CryptoKit
import Foundation
import WiltedDomain

public struct PreparationRun: Sendable {
    public let statuses: AsyncStream<PreparationStatus>
    private let cancellation: @Sendable () async -> Void

    init(statuses: AsyncStream<PreparationStatus>, cancellation: @escaping @Sendable () async -> Void) {
        self.statuses = statuses
        self.cancellation = cancellation
    }

    public func cancel() async { await cancellation() }
}

/// Owns one preparation at a time and emits exactly one terminal status.
public actor PreparationCoordinator {
    typealias ExtractionOperation = @Sendable (URL) async throws -> ExtractedArticle
    typealias SynthesisOperation = @Sendable (String) async throws -> SpeechSynthesisResult
    typealias AssemblyOperation = @Sendable ([Float], ItemID, URL, String) async throws -> AudioAssemblyResult
    typealias SaveOperation = @Sendable (AudioAssemblyResult, Transcript) async throws -> Void

    public static let defaultSocketURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Documents/Projects/speech-stack/.state/speechd.sock")

    /// Per-frame read budget for a `tts_stream`, not a whole-synthesis budget: the
    /// daemon streams one frame per segment and this bounds the gap between them.
    ///
    /// It has to absorb Kokoro cold init (measured ~1.5 s), a cross-process GPU
    /// inference lock held by another workload, and one long segment's generation.
    /// The daemon's own watchdog default for the same gap is 600 s; Wilted stays
    /// tighter so a wedged daemon still fails visibly, and the value is sent as the
    /// request timeout so both sides police the same number.
    public static let defaultSpeechOperationTimeout: TimeInterval = 120

    private let store: LocalLibraryStore
    private let mediaDirectory: URL
    private let socketPath: String
    private let speechOperationTimeout: TimeInterval
    private let extractionOperation: ExtractionOperation?
    private let synthesisOperation: SynthesisOperation?
    private let assemblyOperation: AssemblyOperation?
    private let saveOperation: SaveOperation?
    private var activeTask: Task<Void, Never>?
    private var activeRunID: UUID?

    public init(
        store: LocalLibraryStore,
        mediaDirectory: URL,
        socketPath: String = defaultSocketURL.path,
        speechOperationTimeout: TimeInterval = defaultSpeechOperationTimeout
    ) {
        self.store = store
        self.mediaDirectory = mediaDirectory
        self.socketPath = socketPath
        self.speechOperationTimeout = speechOperationTimeout
        extractionOperation = nil
        synthesisOperation = nil
        assemblyOperation = nil
        saveOperation = nil
    }

    init(
        store: LocalLibraryStore,
        mediaDirectory: URL,
        extraction: @escaping ExtractionOperation,
        synthesis: @escaping SynthesisOperation,
        assembly: @escaping AssemblyOperation,
        save: SaveOperation? = nil
    ) {
        self.store = store
        self.mediaDirectory = mediaDirectory
        socketPath = Self.defaultSocketURL.path
        speechOperationTimeout = Self.defaultSpeechOperationTimeout
        extractionOperation = extraction
        synthesisOperation = synthesis
        assemblyOperation = assembly
        saveOperation = save
    }

    public func start(url: URL) -> PreparationRun {
        activeTask?.cancel()
        let runID = UUID()
        let (stream, continuation) = AsyncStream<PreparationStatus>.makeStream()
        let task = Task { [weak self] in
            guard let self else { continuation.finish(); return }
            await self.prepare(url: url, runID: runID, continuation: continuation)
        }
        activeRunID = runID
        activeTask = task
        return PreparationRun(statuses: stream) { [weak self] in await self?.cancel() }
    }

    public func cancel() { activeTask?.cancel() }

    /// Maps the speech client's `stream.audio samples=N` line to produced audio seconds.
    /// The live rate is unknown until the terminal frame, so the contracted stream rate
    /// drives this display-only estimate.
    private static func producedAudioSeconds(in line: String) -> Double? {
        let prefix = "stream.audio samples="
        guard line.hasPrefix(prefix), let count = Int(line.dropFirst(prefix.count)) else { return nil }
        return Double(count) / Double(SpeechIPCClient.streamSampleRate)
    }

    private func prepare(
        url: URL,
        runID: UUID,
        continuation: AsyncStream<PreparationStatus>.Continuation
    ) async {
        let requestID = UUID().uuidString.lowercased()
        let emitter = PreparationEmitter(requestID: requestID, continuation: continuation, store: store)
        var candidateURL: URL?
        var candidateCommitted = false

        do {
            await emitter.emit(.preparing, "Validating article URL", fraction: 0)
            let extracted: ExtractedArticle
            if let extractionOperation {
                extracted = try await extractionOperation(url)
            } else {
                extracted = try await NativeArticleExtractor().extract(url) { stage, fraction in
                    // The outer coordinator owns domain statuses. The extractor's
                    // callback remains useful for progress without blocking it.
                    _ = stage; _ = fraction
                }
            }
            try Task.checkCancellation()
            let itemID = try ItemID.derive(from: extracted.canonicalURL)
            await emitter.setItemID(itemID)
            let article = try Article(
                itemID: itemID, canonicalURL: extracted.canonicalURL, title: extracted.title,
                source: extracted.source, author: extracted.author, createdAt: Timestamp(Date())
            )
            try await store.save(article: article)
            await emitter.emit(.extracting, "Article text ready", fraction: 0.35)

            await emitter.emit(.synthesizing, "Generating speech", fraction: 0.4)
            let speech: SpeechSynthesisResult
            if let synthesisOperation {
                speech = try await synthesisOperation(extracted.body)
            } else {
                let client = SpeechIPCClient(
                    socketPath: socketPath,
                    connectTimeout: 2,
                    operationTimeout: speechOperationTimeout,
                    status: { line in
                        // Synthesis is the longest leg by far. Relay the daemon's
                        // per-segment progress so the surface never sits silent (W-INV-001).
                        guard let produced = Self.producedAudioSeconds(in: line) else { return }
                        Task { await emitter.emitSynthesisProgress(producedSeconds: produced) }
                    }
                )
                let speechTask = Task.detached { try client.synthesize(text: extracted.body) }
                speech = try await withTaskCancellationHandler {
                    try await speechTask.value
                } onCancel: {
                    speechTask.cancel()
                }
            }
            try Task.checkCancellation()

            await emitter.emit(.assembling, "Assembling audio", fraction: 0.8)
            try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
            let destination = mediaDirectory.appending(path: "candidate-\(requestID).m4a")
            candidateURL = destination
            let textHash = SHA256.hash(data: Data(extracted.body.utf8)).map { String(format: "%02x", $0) }.joined()
            let result: AudioAssemblyResult
            if let assemblyOperation {
                result = try await assemblyOperation(speech.samples, itemID, destination, textHash)
            } else {
                let assemblyTask = Task.detached {
                    try AudioAssembler().assemble(
                        pcm: speech.samples, itemID: itemID, destinationURL: destination,
                        sourceSampleRate: speech.sampleRate,
                        extractedTextSHA256: textHash, isCancelled: { Task.isCancelled }
                    )
                }
                result = try await withTaskCancellationHandler {
                    try await assemblyTask.value
                } onCancel: {
                    assemblyTask.cancel()
                }
            }
            try Task.checkCancellation()

            await emitter.emit(.saving, "Saving to library", fraction: 0.95)
            let transcript: Transcript
            if extracted.body.utf8.count > Transcript.maximumTextUTF8Bytes {
                transcript = try Transcript(
                    itemID: result.revision.itemID,
                    revisionID: result.revision.revisionID,
                    availability: .oversized,
                    updatedAt: result.revision.createdAt
                )
            } else {
                transcript = try Transcript(
                    itemID: result.revision.itemID,
                    revisionID: result.revision.revisionID,
                    availability: .available,
                    text: extracted.body,
                    updatedAt: result.revision.createdAt
                )
            }
            if let saveOperation {
                try await saveOperation(result, transcript)
            } else {
                try await store.saveReadyRevision(result.revision, mediaURL: result.mediaURL, transcript: transcript)
            }
            candidateCommitted = true
            let terminal = try PreparationTerminalResult(outcome: .succeeded, revisionID: result.revision.revisionID)
            await emitter.emit(.completed, "Ready to play", fraction: 1, terminal: terminal)
        } catch is CancellationError, AudioAssemblerError.cancelled {
            let terminal = try? PreparationTerminalResult(outcome: .cancelled)
            await emitter.emit(.cancelled, "Preparation cancelled", terminal: terminal)
        } catch {
            let producerError = try? ProducerError(
                code: mapError(error), message: userMessage(error), retryable: isRetryable(error),
                stage: "preparation", underlyingCode: String(describing: type(of: error))
            )
            let terminal = producerError.flatMap { try? PreparationTerminalResult(outcome: .failed, error: $0) }
            await emitter.emit(.failed, producerError?.message ?? "Preparation failed", terminal: terminal)
        }
        if !candidateCommitted, let candidateURL {
            try? FileManager.default.removeItem(at: candidateURL)
        }
        await emitter.finishIfNeeded()
        if activeRunID == runID {
            activeTask = nil
            activeRunID = nil
        }
    }
}

private actor PreparationEmitter {
    private let requestID: String
    private let continuation: AsyncStream<PreparationStatus>.Continuation
    private let store: LocalLibraryStore
    private var itemID: ItemID?
    private var sequence = 0
    private var terminalEmitted = false
    private var streamFinished = false
    private var lastSynthesisMinute = -1

    init(requestID: String, continuation: AsyncStream<PreparationStatus>.Continuation, store: LocalLibraryStore) {
        self.requestID = requestID
        self.continuation = continuation
        self.store = store
    }

    func setItemID(_ value: ItemID) { itemID = value }

    /// Reports synthesis progress at most once per produced minute so a long article
    /// shows movement without flooding the stream or the preparation journal.
    func emitSynthesisProgress(producedSeconds: Double) async {
        let minute = Int(producedSeconds / 60)
        guard minute > lastSynthesisMinute else { return }
        lastSynthesisMinute = minute
        let detail = minute == 0 ? "Generating speech" : "Generating speech (\(minute) min ready)"
        await emit(.synthesizing, detail, fraction: 0.4)
    }

    func emit(
        _ stage: PreparationStage,
        _ detail: String,
        fraction: Double? = nil,
        terminal: PreparationTerminalResult? = nil
    ) async {
        guard !terminalEmitted,
              let status = try? PreparationStatus(
                stage: stage, detail: detail, fraction: fraction, cancellable: terminal == nil,
                terminalResult: terminal, emittedAt: Timestamp(Date())
              ) else { return }
        continuation.yield(status)
        if let itemID {
            sequence += 1
            let entry = PreparationJournalEntry(
                id: "\(requestID)-\(sequence)", itemID: itemID, requestID: requestID, status: status
            )
            try? await store.record(preparation: entry)
        }
        if terminal != nil { terminalEmitted = true }
    }

    func finishIfNeeded() {
        guard !streamFinished else { return }
        streamFinished = true
        continuation.finish()
    }
}

private func mapError(_ error: Error) -> ProducerErrorCode {
    switch error {
    case ArticleExtractionError.invalidURL: .invalidRequest
    case ArticleExtractionError.unsupported: .unsupported
    case is ArticleExtractionError: .extractionFailed
    case SpeechIPCError.timeout: .timedOut
    case SpeechIPCError.daemon, SpeechIPCError.systemCall: .speechUnavailable
    case SpeechIPCError.unexpectedFrame, SpeechIPCError.invalidControlJSON: .protocolMismatch
    case is AudioAssemblerError: .outputInvalid
    default: .failed
    }
}

private func userMessage(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? String(describing: error)
}

private func isRetryable(_ error: Error) -> Bool {
    switch error {
    case ArticleExtractionError.invalidURL, ArticleExtractionError.unsupported: false
    default: true
    }
}
