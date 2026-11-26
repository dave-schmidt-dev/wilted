import CryptoKit
import Foundation
import WiltedLibrary

public enum ApprovedReadingVoiceID: String, CaseIterable, Codable, Sendable, Identifiable {
    case caseyKasem = "casey-kasem"
    case wolfmanJack = "wolfman-jack"
    case paulHarvey = "paul-harvey"
    case rodSerling = "rod-serling"

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .caseyKasem: "Casey Kasem"
        case .wolfmanJack: "Wolfman Jack"
        case .paulHarvey: "Paul Harvey"
        case .rodSerling: "Rod Serling"
        }
    }

    fileprivate var referenceFilename: String {
        switch self {
        case .caseyKasem: "casey-reference.wav"
        case .wolfmanJack: "wolfman-reference.wav"
        case .paulHarvey: "paul-harvey-reference.wav"
        case .rodSerling: "rod-serling-reference.wav"
        }
    }
}

public struct ArticleNarrationRequest: Sendable, Equatable {
    public let requestID: String
    public let storyID: String
    public let originalURL: URL
    public let voiceID: ApprovedReadingVoiceID
    public let voiceRevision: String
    public let ownerToken: String
    public let generation: UInt64

    public init(
        requestID: String,
        storyID: String,
        originalURL: URL,
        voiceID: ApprovedReadingVoiceID,
        voiceRevision: String,
        ownerToken: String,
        generation: UInt64
    ) {
        self.requestID = requestID
        self.storyID = storyID
        self.originalURL = originalURL
        self.voiceID = voiceID
        self.voiceRevision = voiceRevision
        self.ownerToken = ownerToken
        self.generation = generation
    }
}

public struct ArticleNarrationProgress: Sendable, Equatable {
    public enum Stage: String, Sendable {
        case fetching, extracting, loadingVoice = "loading", synthesizing, saving
    }

    public let stage: Stage
    public let fraction: Double?
}

public struct ArticleNarrationResult: Sendable, Equatable {
    public let audioURL: URL
    public let revisionID: String
    public let contentHash: String
    public let byteCount: Int64
    public let mediaType: String
    public let duration: TimeInterval
    public let voiceRevision: String
    public let canonicalURL: URL
    public let title: String
    public let source: String

    public init(
        audioURL: URL,
        revisionID: String,
        contentHash: String,
        byteCount: Int64,
        mediaType: String,
        duration: TimeInterval,
        voiceRevision: String,
        canonicalURL: URL,
        title: String,
        source: String
    ) {
        self.audioURL = audioURL
        self.revisionID = revisionID
        self.contentHash = contentHash
        self.byteCount = byteCount
        self.mediaType = mediaType
        self.duration = duration
        self.voiceRevision = voiceRevision
        self.canonicalURL = canonicalURL
        self.title = title
        self.source = source
    }
}

/// Local audio made from bounded text with one explicitly selected approved voice.
public struct ArticleNarrationAudio: Sendable, Equatable {
    public let audioURL: URL
    public let duration: TimeInterval
    public let voiceRevision: String

    public init(audioURL: URL, duration: TimeInterval, voiceRevision: String) {
        self.audioURL = audioURL
        self.duration = duration
        self.voiceRevision = voiceRevision
    }
}

public enum ArticleNarrationError: Error, Equatable, LocalizedError, Sendable {
    case invalidRequest
    case articleUnavailable
    case voiceUnavailable
    case modelUnavailable
    case runtimeUnavailable
    case synthesisFailed
    case cancelled
    case invalidAudio
    case audioTooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidRequest: "Wilted could not start this story request."
        case .articleUnavailable: "Wilted could not find readable article text at this link."
        case .voiceUnavailable: "The selected reading voice is not available on this Mac."
        case .modelUnavailable: "The local article narration model is not available on this Mac."
        case .runtimeUnavailable: "The local article narration runtime is not available on this Mac."
        case .synthesisFailed: "Wilted could not create audio for this story."
        case .cancelled: "Story narration was cancelled."
        case .invalidAudio: "Wilted could not verify the generated story audio."
        case .audioTooLarge: "This article is too long for a story audio download."
        }
    }
}

public enum ArticleVoiceAvailability: Equatable, Sendable {
    case available
    case missingVoice
    case missingModel
    case missingRuntime
}

public struct ArticleNarrationConfiguration: Sendable {
    public let pythonURL: URL
    public let helperURL: URL
    public let workerDirectory: URL
    public let modelDirectory: URL
    public let referenceDirectory: URL
    public let encoderURL: URL

    public init(
        pythonURL: URL,
        helperURL: URL,
        modelDirectory: URL,
        referenceDirectory: URL,
        workerDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Documents/Projects/wilted/Producer/Workers"),
        encoderURL: URL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
    ) {
        self.pythonURL = pythonURL
        self.helperURL = helperURL
        self.workerDirectory = workerDirectory
        self.modelDirectory = modelDirectory
        self.referenceDirectory = referenceDirectory
        self.encoderURL = encoderURL
    }

    public static func resolved(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Self {
        let fileManager = FileManager.default
        let encoder = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
            .map { URL(fileURLWithPath: $0) }
            .first { fileManager.isExecutableFile(atPath: $0.path) }
            ?? URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        let helper = Bundle.main.url(forResource: "article_voice", withExtension: "py")
            ?? home.appending(path: "Documents/Projects/wilted/Producer/Runtime/src/wilted/article_voice.py")
        return Self(
            pythonURL: home.appending(path: ".venvs/speech/bin/python"),
            helperURL: helper,
            modelDirectory: home.appending(path: "Documents/Projects/chatterbox/models/chatterbox-turbo-8bit"),
            referenceDirectory: home.appending(path: "Documents/Projects/chatterbox/reference-audio/prepared"),
            workerDirectory: home.appending(path: "Documents/Projects/wilted/Producer/Workers"),
            encoderURL: encoder
        )
    }
}

/// Extracts article text on Mac and synthesizes a voice-selected private M4A without saving a transcript.
public struct ArticleNarrationCoordinator: Sendable {
    public static let engineRevision = "chatterbox-turbo-mlx-aac96-r1"
    public static let maximumShortTextUTF8Bytes = Bulletin.maximumTextUTF8Bytes
    public static let maximumShortTextDuration: TimeInterval = 900
    private static let shortTextEngineRevision = "chatterbox-turbo-mlx-aac96-loudnorm-r1"

    struct SynthesisMetadata: Sendable {
        let duration: TimeInterval
        let byteCount: Int64
    }

    typealias SynthesisOperation = @Sendable (
        URL, URL, ApprovedReadingVoiceID, @Sendable (ArticleNarrationProgress) -> Void
    ) async throws -> SynthesisMetadata

    private let configuration: ArticleNarrationConfiguration
    private let extractor: NativeArticleExtractor
    private let synthesisOperation: SynthesisOperation?

    public init(
        configuration: ArticleNarrationConfiguration = .resolved(),
        extractor: NativeArticleExtractor = NativeArticleExtractor(loader: PublicHTTPSArticleTransport())
    ) {
        self.configuration = configuration
        self.extractor = extractor
        synthesisOperation = nil
    }

    init(
        configuration: ArticleNarrationConfiguration,
        extractor: NativeArticleExtractor,
        synthesize: @escaping SynthesisOperation
    ) {
        self.configuration = configuration
        self.extractor = extractor
        synthesisOperation = synthesize
    }

    public func availability(for voiceID: ApprovedReadingVoiceID) -> ArticleVoiceAvailability {
        guard FileManager.default.isExecutableFile(atPath: configuration.pythonURL.path),
              FileManager.default.isReadableFile(atPath: configuration.helperURL.path),
              ["__init__.py", "gpu_admission.py", "reporting.py", "constants.py"].allSatisfy({
                  FileManager.default.isReadableFile(
                      atPath: configuration.workerDirectory.appending(path: "wilted_worker/\($0)").path
                  )
              }),
              FileManager.default.isExecutableFile(atPath: configuration.encoderURL.path) else {
            return .missingRuntime
        }
        guard FileManager.default.fileExists(atPath: configuration.modelDirectory.appending(path: "model.safetensors").path),
              FileManager.default.fileExists(atPath: configuration.modelDirectory.appending(path: "config.json").path) else {
            return .missingModel
        }
        let reference = configuration.referenceDirectory.appending(path: voiceID.referenceFilename)
        return FileManager.default.isReadableFile(atPath: reference.path) ? .available : .missingVoice
    }

    public static func voiceRevision(for voiceID: ApprovedReadingVoiceID) -> String {
        "\(engineRevision):\(voiceID.rawValue)"
    }

    public static func shortTextVoiceRevision(for voiceID: ApprovedReadingVoiceID) -> String {
        "\(shortTextEngineRevision):\(voiceID.rawValue)"
    }

    public func narrate(
        _ request: ArticleNarrationRequest,
        outputURL: URL,
        progress: @escaping @Sendable (ArticleNarrationProgress) -> Void = { _ in }
    ) async throws -> ArticleNarrationResult {
        guard !request.requestID.isEmpty, !request.storyID.isEmpty, !request.ownerToken.isEmpty,
              request.voiceRevision == Self.voiceRevision(for: request.voiceID),
              request.originalURL.scheme?.lowercased() == "https", request.originalURL.host != nil,
              outputURL.pathExtension.lowercased() == "m4a" else {
            throw ArticleNarrationError.invalidRequest
        }
        switch availability(for: request.voiceID) {
        case .available: break
        case .missingVoice: throw ArticleNarrationError.voiceUnavailable
        case .missingModel: throw ArticleNarrationError.modelUnavailable
        case .missingRuntime: throw ArticleNarrationError.runtimeUnavailable
        }
        try Task.checkCancellation()
        progress(ArticleNarrationProgress(stage: .fetching, fraction: nil))
        let article: ExtractedArticle
        do {
            article = try await extractor.extract(request.originalURL) { stage, fraction in
                if stage == .selectingContent || stage == .finished {
                    progress(ArticleNarrationProgress(stage: .extracting, fraction: fraction))
                } else if stage == .fetching {
                    progress(ArticleNarrationProgress(stage: .fetching, fraction: fraction))
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ArticleNarrationError.articleUnavailable
        }
        try Task.checkCancellation()

        let textHash = Self.sha256(Data(article.body.utf8))
        let revisionID = Self.sha256(Data("\(request.storyID)\0\(textHash)\0\(request.voiceRevision)".utf8))
        let workspace = FileManager.default.temporaryDirectory.appending(path: "wilted-article-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let textURL = workspace.appending(path: "article.txt")
        do {
            try Data(article.body.utf8).write(to: textURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: textURL.path)
            defer { try? FileManager.default.removeItem(at: workspace) }
            progress(ArticleNarrationProgress(stage: .loadingVoice, fraction: nil))
            let metadata = try await synthesize(
                textURL: textURL, outputURL: outputURL, voiceID: request.voiceID, progress: progress
            )
            try Task.checkCancellation()
            guard metadata.byteCount > 44, metadata.duration > 0,
                  FileManager.default.fileExists(atPath: outputURL.path) else {
                throw ArticleNarrationError.invalidAudio
            }
            return ArticleNarrationResult(
                audioURL: outputURL,
                revisionID: revisionID,
                contentHash: try Self.sha256(fileAt: outputURL),
                byteCount: metadata.byteCount,
                mediaType: "audio/mp4",
                duration: metadata.duration,
                voiceRevision: request.voiceRevision,
                canonicalURL: article.canonicalURL,
                title: article.title,
                source: article.source
            )
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: workspace)
            throw error
        }
    }

    /// Renders a short local announcement without fetching the linked article.
    /// Text is kept in a private temporary workspace and is never logged.
    public func synthesizeShortText(
        _ text: String,
        voiceID: ApprovedReadingVoiceID,
        outputURL: URL,
        progress: @escaping @Sendable (ArticleNarrationProgress) -> Void = { _ in }
    ) async throws -> ArticleNarrationAudio {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= Self.maximumShortTextUTF8Bytes,
              outputURL.pathExtension.lowercased() == "m4a" else {
            throw ArticleNarrationError.invalidRequest
        }
        switch availability(for: voiceID) {
        case .available: break
        case .missingVoice: throw ArticleNarrationError.voiceUnavailable
        case .missingModel: throw ArticleNarrationError.modelUnavailable
        case .missingRuntime: throw ArticleNarrationError.runtimeUnavailable
        }
        try Task.checkCancellation()
        let workspace = FileManager.default.temporaryDirectory
            .appending(path: "wilted-headline-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let textURL = workspace.appending(path: "announcement.txt")
        do {
            try Data(trimmed.utf8).write(to: textURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: textURL.path)
            defer { try? FileManager.default.removeItem(at: workspace) }
            progress(ArticleNarrationProgress(stage: .loadingVoice, fraction: nil))
            let metadata = try await synthesize(
                textURL: textURL, outputURL: outputURL, voiceID: voiceID,
                normalizeLoudness: true, progress: progress)
            try Task.checkCancellation()
            guard metadata.byteCount > 44, metadata.duration > 0,
                  metadata.duration <= Self.maximumShortTextDuration,
                  FileManager.default.fileExists(atPath: outputURL.path) else {
                throw ArticleNarrationError.invalidAudio
            }
            return ArticleNarrationAudio(
                audioURL: outputURL, duration: metadata.duration,
                voiceRevision: Self.shortTextVoiceRevision(for: voiceID))
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: workspace)
            throw error
        }
    }

    private func synthesize(
        textURL: URL,
        outputURL: URL,
        voiceID: ApprovedReadingVoiceID,
        normalizeLoudness: Bool = false,
        progress: @escaping @Sendable (ArticleNarrationProgress) -> Void
    ) async throws -> SynthesisMetadata {
        if let synthesisOperation {
            return try await synthesisOperation(textURL, outputURL, voiceID, progress)
        }
        let processBox = NarrationProcessBox()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                let process = Process()
                let pipe = Pipe()
                process.executableURL = configuration.pythonURL
                var arguments = [
                    configuration.helperURL.path,
                    "synthesize",
                    "--voice-id", voiceID.rawValue,
                    "--text-file", textURL.path,
                    "--output", outputURL.path
                ]
                if normalizeLoudness { arguments.append("--normalize-loudness") }
                process.arguments = arguments
                process.environment = [
                    "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                    "PATH": "\(configuration.encoderURL.deletingLastPathComponent().path):/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                    "PYTHONPATH": configuration.workerDirectory.path,
                    "PYTHONUNBUFFERED": "1",
                    "PYTHONDONTWRITEBYTECODE": "1",
                    "HF_HUB_OFFLINE": "1",
                    "TRANSFORMERS_OFFLINE": "1"
                ]
                process.qualityOfService = .utility
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                try processBox.start(process)
                defer { processBox.clear() }
                var event: [String: Any]?
                var buffered = Data()
                while true {
                    let bytes = try pipe.fileHandleForReading.read(upToCount: 4 * 1_024) ?? Data()
                    if bytes.isEmpty { break }
                    buffered.append(bytes)
                    while let newline = buffered.firstIndex(of: 10) {
                        let line = buffered.prefix(upTo: newline)
                        buffered.removeSubrange(...newline)
                        guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                              let kind = object["event"] as? String else { continue }
                        if kind == "error" { event = object }
                        if kind == "progress", let stageName = object["stage"] as? String,
                           let stage = ArticleNarrationProgress.Stage(rawValue: stageName) {
                            progress(ArticleNarrationProgress(stage: stage, fraction: object["fraction"] as? Double))
                        }
                        if kind == "complete" { event = object }
                    }
                }
                process.waitUntilExit()
                if processBox.wasCancelled { throw CancellationError() }
                guard process.terminationReason == .exit, process.terminationStatus == 0,
                      let event, event["event"] as? String == "complete",
                      let sampleRate = event["sampleRate"] as? Double, sampleRate > 0,
                      let duration = event["durationMilliseconds"] as? Double, duration > 0 else {
                    let code = event?["code"] as? String
                    switch code {
                    case "missing_voice": throw ArticleNarrationError.voiceUnavailable
                    case "missing_model": throw ArticleNarrationError.modelUnavailable
                    case "missing_encoder": throw ArticleNarrationError.runtimeUnavailable
                    case "audio_too_large": throw ArticleNarrationError.audioTooLarge
                    case "unsupported_voice": throw ArticleNarrationError.invalidRequest
                    case "cancelled": throw ArticleNarrationError.cancelled
                    default: throw ArticleNarrationError.synthesisFailed
                    }
                }
                let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
                return SynthesisMetadata(
                    duration: duration / 1_000,
                    byteCount: attributes[.size] as? Int64 ?? Int64(attributes[.size] as? Int ?? 0)
                )
            }.value
        } onCancel: {
            processBox.cancel()
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256(fileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let bytes = try handle.read(upToCount: 1 * 1_024 * 1_024), !bytes.isEmpty {
            hasher.update(data: bytes)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private final class NarrationProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var wasCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func start(_ process: Process) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        try process.run()
        self.process = process
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let active = process
        let isRunning = active?.isRunning == true
        lock.unlock()
        if isRunning { active?.terminate() }
    }

    func clear() {
        lock.lock()
        process = nil
        lock.unlock()
    }
}
