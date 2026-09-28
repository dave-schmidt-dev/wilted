import CryptoKit
import Foundation
import WiltedDomain

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
    /// Manually bumped when the semantic preparation behavior changes. This is
    /// deliberately independent of the app or UI build number so a launch can
    /// identify old preparation results without invalidating unrelated work.
    public static let semanticVersion = "podcast-preparation-v5"
    /// The worker is part of the semantic pipeline even though it lives in a
    /// separate Python source tree. Update this alongside the fingerprint when
    /// that worker changes.
    public static let workerSourceHash = "sha256:8fcdd5854013c565e2cfc28f4b5b8edc8b73804b5e875afc98c4554fb736d42d"
    /// This file's own source hash is computed with this value normalized out;
    /// it makes a semantic edit fail the coverage test until this fingerprint
    /// block is deliberately updated.
    public static let pipelineSourceHash = "sha256:65e97400b4e5bf63d3200c8aee32d60e633a2b559887f6c44b00e0a6ed68dd85"

    /// Includes the external Python packages imported by the worker. The
    /// runtime itself now lives in this repository under `Producer/Runtime`,
    /// but `speech-stack` is still an editable dependency resolved outside it,
    /// so a constant-only fingerprint would miss a detector or transcription
    /// change made between app builds.
    public static let semanticFingerprintResolution = resolvedSemanticFingerprint()
    /// The sentinel a caller sees when resolution failed.
    ///
    /// Nothing durable may carry it. A stored outcome stamped `-unresolved`
    /// becomes false provenance the moment a real fingerprint resolves: the
    /// comparison then reads as semantic drift and invalidates work that was
    /// never stale. Every stamping site takes the optional resolution and
    /// omits the field instead, so this exists for display and for tests.
    public static let semanticFingerprint = semanticFingerprintResolution
        ?? semanticVersion + "-unresolved"

    /// Resolution off the launch path.
    ///
    /// `semanticFingerprintResolution` memory-maps the worker and hashes two
    /// Python source trees. It is a lazy `static let`, so whichever caller
    /// touches it first pays for it — and that caller used to be
    /// `WiltedMacApp.init`, on the main thread, before the first frame.
    /// Awaiting this instead moves the work to a utility thread while keeping
    /// the `static let` as the single source of the value, so it still runs
    /// exactly once and still returns exactly what the synchronous path does.
    public static func resolveSemanticFingerprintOffMainPath() async -> String? {
        await Task.detached(priority: .utility) { semanticFingerprintResolution }.value
    }

    /// Reprocessing-eligibility rules for `invalidateStalePodcastPreparations`.
    /// Starts empty: a fingerprint drift with no rule here invalidates
    /// nothing, so unrelated pipeline edits (comments, logging, a refactor
    /// with no output effect) never force a redownload or re-preparation.
    /// Add a rule only when a specific pipeline change actually makes prior
    /// output wrong.
    public static let invalidationRules: [PodcastPreparationInvalidationRule] = []

    public static func resolvedSemanticFingerprint(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let configuration = SubprocessPodcastPipelineRunner.Configuration.resolved(environment: environment)
        var hasher = SHA256()
        func include(_ value: String) {
            hasher.update(data: Data(value.utf8))
            hasher.update(data: Data([0]))
        }
        include(semanticVersion)
        include(workerSourceHash)
        include(pipelineSourceHash)
        guard let workerData = try? Data(contentsOf: configuration.workerURL, options: .mappedIfSafe) else {
            return nil
        }
        include("worker")
        hasher.update(data: workerData)

        let fileManager = FileManager.default
        let workerPackage = configuration.workerURL.deletingLastPathComponent()
            .appendingPathComponent("wilted_worker")
        if fileManager.fileExists(atPath: workerPackage.path) {
            var enumerationFailed = false
            guard let enumerator = fileManager.enumerator(
                at: workerPackage, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsPackageDescendants],
                errorHandler: { _, _ in
                    enumerationFailed = true
                    return false
                }
            ) else { return nil }
            var packageFiles: [URL] = []
            for case let url as URL in enumerator {
                if url.lastPathComponent == "__pycache__" {
                    enumerator.skipDescendants()
                    continue
                }
                guard url.pathExtension == "py" else { continue }
                do {
                    if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                        packageFiles.append(url)
                    }
                } catch {
                    enumerationFailed = true
                    break
                }
            }
            guard !enumerationFailed else { return nil }
            for url in packageFiles.sorted(by: { $0.path < $1.path }) {
                include(String(url.path.dropFirst(workerPackage.path.count + 1)))
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
                hasher.update(data: data)
            }
        }

        guard let sourceRoot = configuration.pythonPath else { return nil }
        let speechSourceRoot = environment["WILTED_SPEECH_STACK_PYTHONPATH"]
            .map { URL(fileURLWithPath: $0) }
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Projects/speech-stack/src")
        let packageRoots = [
            (sourceRoot, sourceRoot.appendingPathComponent("wilted")),
            (speechSourceRoot, speechSourceRoot.appendingPathComponent("speech_stack"))
        ]
        var sourceFiles: [URL] = []
        for (_, root) in packageRoots {
            var enumerationFailed = false
            guard let enumerator = fileManager.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in
                    enumerationFailed = true
                    return false
                }
            ) else { return nil }
            var files: [URL] = []
            for case let url as URL in enumerator where url.pathExtension == "py" {
                do {
                    if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                        files.append(url)
                    }
                } catch {
                    enumerationFailed = true
                    break
                }
            }
            guard !enumerationFailed, !files.isEmpty else { return nil }
            sourceFiles.append(contentsOf: files)
        }
        sourceFiles.sort { $0.path < $1.path }
        for url in sourceFiles {
            let owningRoot = packageRoots.first { url.path.hasPrefix($0.0.path) }?.0 ?? sourceRoot
            include(String(url.path.dropFirst(owningRoot.path.count)))
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
            hasher.update(data: data)
        }
        return "sha256:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// A published transcript larger than this is not a transcript.
    public static let maximumTranscriptDocumentBytes = 8 * 1_024 * 1_024
    /// The detector was tuned against this exact aligned STT output. This is
    /// sent explicitly with the verified download hash so the worker cache
    /// cannot be reused by a different model or source revision.
    public static let alignedTranscriptModel = "mlx-community/parakeet-tdt-1.1b"

    let store: LocalLibraryStore
    private let runner: any PodcastPipelineRunning
    private let documentLoader: any PodcastFeedLoading
    let workDirectory: URL
    private let defaultPolicy: PodcastPreparationPolicySnapshot
    let now: @Sendable () -> Date

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
        self.defaultPolicy = PodcastPreparationPolicySnapshot(
            transcriptPolicy: allowSpeechToText ? .bestAvailable : .noLocalSTT,
            removeAds: removeAds
        )
        self.now = now
    }

    /// The journal key for one episode's preparation history.
    public static func requestID(for episodeID: ItemID) -> String { "podcast-prepare|" + episodeID.rawValue }

    public func prepare(
        episodeID: ItemID,
        policy: PodcastPreparationPolicySnapshot? = nil,
        onStatus: @escaping @Sendable (PodcastPreparationProgress) -> Void = { _ in }
    ) async throws -> PodcastPreparationResult {
        let policy = policy ?? defaultPolicy
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
                                  error: PodcastPreparationError.episodeNotDownloaded, revisionID: nil,
                                  fingerprint: Self.semanticFingerprintResolution)
            throw PodcastPreparationError.episodeNotDownloaded
        }

        var provenanceFields = [
            "sourceRevisionID": stored.revision.revisionID.rawValue,
            "sourceHash": stored.revision.contentHash,
        ]
        // Omitted rather than stamped with the sentinel: an absent fingerprint
        // reads as "not recorded", which is true, where `-unresolved` would
        // later read as a different pipeline.
        if let fingerprint = Self.semanticFingerprintResolution {
            provenanceFields["fingerprint"] = fingerprint
        }
        let provenance = try? PreparationEvidence(kind: LocalLibraryStore.pipelineProvenanceEvidenceKind,
                                                  fields: provenanceFields)
        report(PodcastPreparationProgress(stage: "pipeline.start", detail: episode.title, evidence: provenance))
        do {
            var request: [String: Any] = [
                "protocolVersion": 2,
                "audioPath": audioURL.path,
                "outputPath": preparedAudioURL(for: audioURL).path,
                "workDir": workDirectory.path,
                "transcriptPolicy": policy.transcriptPolicy.rawValue,
                "removeAds": policy.removeAds,
                "allowSpeechToText": policy.transcriptPolicy != .noLocalSTT,
                "sourceHash": stored.revision.contentHash,
                "alignedTranscriptModel": Self.alignedTranscriptModel,
            ]
            // The worker echoes this back into the result it stores. Sending
            // the sentinel would persist it one layer further out.
            if let fingerprint = Self.semanticFingerprintResolution {
                request["pipelineFingerprint"] = fingerprint
            }
            if !policy.removeAds, policy.transcriptPolicy != .alwaysTranscribe,
               let published = await fetchPublishedTranscript(for: episode, onStatus: report) {
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
                                          downloadedRevision: stored.revision, audioURL: audioURL,
                                          policy: policy, onStatus: report)
            await writes.drain()
            await journalTerminal(episodeID: episodeID, requestID: requestID, error: nil,
                                  revisionID: result.revision.revisionID, summary: result.summary,
                                  fingerprint: Self.semanticFingerprintResolution,
                                  sourceRevisionID: stored.revision.revisionID,
                                  sourceHash: stored.revision.contentHash,
                                  sourceURL: audioURL,
                                  timeline: payload.timeline)
            return result
        } catch {
            await writes.drain()
            await journalTerminal(episodeID: episodeID, requestID: requestID, error: error, revisionID: nil,
                                  fingerprint: Self.semanticFingerprintResolution,
                                  sourceRevisionID: stored.revision.revisionID,
                                  sourceHash: stored.revision.contentHash,
                                  sourceURL: audioURL)
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
        summary: String? = nil, fingerprint: String? = nil,
        sourceRevisionID: RevisionID? = nil, sourceHash: String? = nil, sourceURL: URL? = nil,
        timeline: PreparationStatus.PreparationTimeline? = nil
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
        let evidence = fingerprint.flatMap({ value in
            var fields = [
                "fingerprint": value,
                "sourceRevisionID": sourceRevisionID?.rawValue ?? "",
                "sourceHash": sourceHash ?? "",
            ]
            if let sourceURL, sourceURL.absoluteString.count <= 256 {
                fields["sourceURL"] = sourceURL.absoluteString
            }
            return try? PreparationEvidence(kind: LocalLibraryStore.pipelineProvenanceEvidenceKind, fields: fields)
        })
        guard outcome != .failed || producerError != nil,
              let terminal = try? PreparationTerminalResult(outcome: outcome, revisionID: revisionID,
                                                            error: producerError),
              let status = try? PreparationStatus(
                stage: outcome == .succeeded ? .completed : (outcome == .cancelled ? .cancelled : .failed),
                detail: producerError?.message ?? (outcome == .succeeded ? (summary ?? "Prepared.") : "Cancelled."),
                cancellable: false, terminalResult: terminal, emittedAt: Timestamp(now()),
                evidence: evidence,
                timeline: outcome == .succeeded ? timeline : nil
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

}
