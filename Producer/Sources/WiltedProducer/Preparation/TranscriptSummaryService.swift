import CryptoKit
import Darwin
import Foundation

public enum TranscriptSummaryError: Error, Equatable, Sendable {
    case emptyTranscript
    case modelUnavailable
    case modelChanged
    case malformedResponse
    case identityMismatch
    case incompleteResponse
    case workerFailed(code: String, message: String)
}

/// The summary operation's wire request; preparation requests remain unchanged.
public struct TranscriptSummaryRequest: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let operation: String
    public let requestID: String
    public let transcriptText: String
    public let llmModel: String

    public init(transcript: String, modelURL: URL, requestID: UUID) {
        protocolVersion = 2
        operation = "summary"
        self.requestID = requestID.uuidString.lowercased()
        transcriptText = transcript
        llmModel = modelURL.resolvingSymlinksInPath().standardizedFileURL.path
    }
}

/// A whole-transcript result validated against the admitted input and local model.
public struct TranscriptSummaryResult: Equatable, Sendable {
    public let summary: String
    public let requestID: UUID
    public let transcriptDigest: String
    public let promptIdentity: String
    public let modelIdentity: String
    public let modelURL: URL
    public let inputCharacters: Int
    public let coverageRanges: [[Int]]
    public let reductionLevels: Int
    public let completionTokens: Int
}

/// Reuses the existing per-call pipeline runner; it owns no process controller or cache.
public struct TranscriptSummaryService: Sendable {
    public struct Configuration: Sendable {
        public let modelURL: URL
        public init(modelURL: URL) { self.modelURL = modelURL }

        /// Mirrors the existing Python runtime's local selection; it never fetches a model.
        public static func resolved(environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
            let configured = environment["LOCAL_MODELS_DIR"].flatMap { value in
                value.isEmpty ? nil : (value as NSString).expandingTildeInPath
            }
            let base = configured.map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("models")
            return Self(modelURL: base.appendingPathComponent(
                "gemma-4-repaired/gemma-4-E4B_q4_0-it-2026-07-15-repaired.gguf"
            ))
        }
    }

    private let runner: any PodcastPipelineRunning

    public init(runner: any PodcastPipelineRunning = SubprocessPodcastPipelineRunner()) {
        self.runner = runner
    }

    /// Resolve the current selected bytes before a caller considers a cached summary.
    /// Uses the same cancellable, stat-fenced hash as an uncached summary request.
    public static func modelIdentity(
        at modelURL: URL,
        requestID: UUID = UUID(),
        onProgress: @escaping @Sendable (PodcastPreparationProgress) -> Void = { _ in }
    ) async throws -> String {
        let selectedModel = try validatedModelURL(modelURL)
        let binding = try await captureModel(selectedModel, requestID: requestID, onProgress: onProgress)
        try Task.checkCancellation()
        return binding.digest
    }

    private static func validatedModelURL(_ modelURL: URL) throws -> URL {
        try Task.checkCancellation()
        guard modelURL.isFileURL, modelURL.path.hasPrefix("/"), modelURL.pathExtension.lowercased() == "gguf" else {
            throw TranscriptSummaryError.modelUnavailable
        }
        return modelURL.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func captureModel(
        _ selectedModel: URL, requestID: UUID,
        onProgress: @escaping @Sendable (PodcastPreparationProgress) -> Void
    ) async throws -> SummaryModelBinding {
        try Task.checkCancellation()
        onProgress(PodcastPreparationProgress(stage: "summary.model.verify", detail: "Verifying local summarizer",
                                             requestID: requestID))
        let hashing = Task.detached(priority: .utility) {
            try SummaryModelBinding.capture(selectedModel, requestID: requestID, onProgress: onProgress)
        }
        let binding = try await withTaskCancellationHandler {
            try await hashing.value
        } onCancel: {
            hashing.cancel()
        }
        try Task.checkCancellation()
        return binding
    }

    public func summarize(
        transcript: String,
        modelURL: URL,
        requestID: UUID = UUID(),
        expectedModelIdentity: String? = nil,
        expectedPromptIdentity: String? = nil,
        onProgress: @escaping @Sendable (PodcastPreparationProgress) -> Void = { _ in }
    ) async throws -> TranscriptSummaryResult {
        try Task.checkCancellation()
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranscriptSummaryError.emptyTranscript
        }
        let selectedModel = try Self.validatedModelURL(modelURL)
        let binding = try await Self.captureModel(selectedModel, requestID: requestID, onProgress: onProgress)
        try Task.checkCancellation()
        if let expectedModelIdentity, expectedModelIdentity != binding.digest {
            throw TranscriptSummaryError.identityMismatch
        }
        if let expectedPromptIdentity, !Self.isDigest(expectedPromptIdentity) {
            throw TranscriptSummaryError.identityMismatch
        }
        let request = TranscriptSummaryRequest(transcript: transcript, modelURL: selectedModel, requestID: requestID)
        let payload = try JSONEncoder().encode(request)
        let response = try await runner.run(request: payload) { progress in
            guard progress.requestID == requestID, progress.stage.hasPrefix("summary.") else { return }
            onProgress(progress)
        }
        try Task.checkCancellation()
        let checking = Task.detached(priority: .utility) { try binding.requireUnchanged(selectedModel) }
        try await withTaskCancellationHandler {
            try await checking.value
        } onCancel: {
            checking.cancel()
        }
        try Task.checkCancellation()
        let result = try Self.validate(response, request: request, transcript: transcript,
                                       binding: binding, modelURL: selectedModel,
                                       expectedPromptIdentity: expectedPromptIdentity)
        try Task.checkCancellation()
        return result
    }

    private static func validate(
        _ data: Data, request: TranscriptSummaryRequest, transcript: String,
        binding: SummaryModelBinding, modelURL: URL, expectedPromptIdentity: String?
    ) throws -> TranscriptSummaryResult {
        let response: SummaryWorkerResponse
        do { response = try JSONDecoder().decode(SummaryWorkerResponse.self, from: data) }
        catch { throw TranscriptSummaryError.malformedResponse }
        guard response.operation == request.operation, response.protocolVersion == request.protocolVersion,
              response.requestID == request.requestID else { throw TranscriptSummaryError.identityMismatch }
        guard response.ok else {
            guard let code = response.code, !code.isEmpty, let message = response.message else {
                throw TranscriptSummaryError.malformedResponse
            }
            throw TranscriptSummaryError.workerFailed(code: code, message: message)
        }
        let digest = SHA256.hash(data: Data(transcript.utf8)).map { String(format: "%02x", $0) }.joined()
        guard response.transcriptDigest == digest, response.modelPath == modelURL.path,
              response.modelIdentity == binding.digest, let promptIdentity = response.promptIdentity,
              isDigest(promptIdentity), expectedPromptIdentity.map({ $0 == promptIdentity }) ?? true else {
            throw TranscriptSummaryError.identityMismatch
        }
        let count = transcript.unicodeScalars.count // Python len(str), not Swift grapheme clusters or UTF-16 units.
        guard response.coverage == "whole", response.inputCharacters == count,
              let summary = response.summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let ranges = response.coverageRanges, !ranges.isEmpty,
              let levels = response.reductionLevels, levels >= 0,
              let tokens = response.completionTokens, tokens > 0 else {
            throw TranscriptSummaryError.incompleteResponse
        }
        var cursor = 0
        for range in ranges {
            guard range.count == 2, range[0] == cursor, range[1] > cursor, range[1] <= count else {
                throw TranscriptSummaryError.incompleteResponse
            }
            cursor = range[1]
        }
        guard cursor == count, ranges.count == 1 ? levels == 0 : (levels > 0 && levels < ranges.count) else {
            throw TranscriptSummaryError.incompleteResponse
        }
        // Every mapped passage and every reduction level generates at least
        // one token. A decreasing reduction tree has at most N-1 new nodes;
        // the summary worker reserves at most 512 output tokens per call.
        let maximumCalls = ranges.count.addingReportingOverflow(ranges.count - 1)
        let maximumTokens = maximumCalls.partialValue.multipliedReportingOverflow(by: 512)
        let minimumTokens = ranges.count.addingReportingOverflow(levels)
        guard !maximumCalls.overflow, !maximumTokens.overflow, !minimumTokens.overflow,
              tokens >= minimumTokens.partialValue, tokens <= maximumTokens.partialValue else {
            throw TranscriptSummaryError.incompleteResponse
        }
        return TranscriptSummaryResult(summary: summary, requestID: UUID(uuidString: request.requestID)!,
            transcriptDigest: digest, promptIdentity: promptIdentity, modelIdentity: binding.digest,
            modelURL: modelURL, inputCharacters: count, coverageRanges: ranges,
            reductionLevels: levels, completionTokens: tokens)
    }

    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

private struct SummaryWorkerResponse: Decodable {
    let ok: Bool
    let protocolVersion: Int
    let operation: String
    let requestID: String
    let summary: String?
    let coverage: String?
    let inputCharacters: Int?
    let coverageRanges: [[Int]]?
    let reductionLevels: Int?
    let completionTokens: Int?
    let transcriptDigest: String?
    let promptIdentity: String?
    let modelIdentity: String?
    let modelPath: String?
    let code: String?
    let message: String?
}

private struct SummaryModelBinding: Sendable {
    private struct Identity: Equatable, Sendable {
        let device: Int64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64
        init(_ status: stat) throws {
            guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
                throw TranscriptSummaryError.modelUnavailable
            }
            device = Int64(status.st_dev)
            inode = UInt64(status.st_ino)
            size = status.st_size
            modifiedSeconds = Int64(status.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(status.st_mtimespec.tv_nsec)
            changedSeconds = Int64(status.st_ctimespec.tv_sec)
            changedNanoseconds = Int64(status.st_ctimespec.tv_nsec)
        }
    }
    let digest: String
    private let identity: Identity

    private static func identity(at url: URL) throws -> Identity {
        try url.withUnsafeFileSystemRepresentation { path in
            var status = stat()
            guard let path, lstat(path, &status) == 0 else { throw TranscriptSummaryError.modelUnavailable }
            return try Identity(status)
        }
    }

    static func capture(_ url: URL, requestID: UUID,
                        onProgress: @escaping @Sendable (PodcastPreparationProgress) -> Void) throws -> Self {
        let before = try identity(at: url)
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) } catch { throw TranscriptSummaryError.modelUnavailable }
        defer { try? handle.close() }
        var status = stat()
        guard fstat(handle.fileDescriptor, &status) == 0, try Identity(status) == before else {
            throw TranscriptSummaryError.modelChanged
        }
        var hash = SHA256()
        var nextProgress = Date().addingTimeInterval(1)
        while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty {
            try Task.checkCancellation()
            hash.update(data: bytes)
            if Date() >= nextProgress {
                onProgress(PodcastPreparationProgress(stage: "summary.model.verify", detail: "Verifying local summarizer",
                                                     requestID: requestID))
                nextProgress = Date().addingTimeInterval(1)
            }
        }
        guard fstat(handle.fileDescriptor, &status) == 0, try Identity(status) == before,
              try identity(at: url) == before else { throw TranscriptSummaryError.modelChanged }
        return Self(digest: hash.finalize().map { String(format: "%02x", $0) }.joined(), identity: before)
    }

    func requireUnchanged(_ url: URL) throws {
        try Task.checkCancellation()
        do {
            guard try Self.identity(at: url) == identity else { throw TranscriptSummaryError.modelChanged }
        } catch { throw TranscriptSummaryError.modelChanged }
    }
}
