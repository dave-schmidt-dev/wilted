import CryptoKit
import Foundation
import WiltedDomain

/// Preferences, counter, key store and sender the pipeline uses for online labelling.
public struct PodcastLabellingServices: Sendable {
    public let preferences: AdLabellerPreferences
    public let counter: LabellerRequestCounter
    public let keyStore: any LabellerKeyStoring
    public let sender: any LabellerSending

    public init(
        preferences: AdLabellerPreferences,
        counter: LabellerRequestCounter,
        keyStore: any LabellerKeyStoring,
        sender: any LabellerSending
    ) {
        self.preferences = preferences
        self.counter = counter
        self.keyStore = keyStore
        self.sender = sender
    }
}

/// Provenance folded into ``PodcastPreparationPipeline/policyDigest(_:labelled:)`` for a remote cut.
public struct LabelledRunProvenance: Equatable, Sendable {
    /// Always ``remote`` for an outcome produced on the labelled path.
    public let route: String
    public let modelID: String
    public let level: String
    public let promptVersion: String

    public init(route: String, modelID: String, level: String, promptVersion: String) {
        self.route = route
        self.modelID = modelID
        self.level = level
        self.promptVersion = promptVersion
    }
}

extension PodcastPreparationPipeline {
    /// The worker's typed error when the aligned transcript no longer matches the labelled cues.
    static let labelledCuesMismatchCode = "labelled-cues-mismatch"

    /// Decoded worker payload plus labelled provenance when the remote route ran.
    struct PreparationWorkerRun: Sendable {
        var payload: WorkerPayload
        var labelledProvenance: LabelledRunProvenance?
    }

    /// Where an episode that qualifies for online labelling goes first.
    enum LabelledRouting: Sendable {
        /// Transcript, one labelling request, cut.
        case remote
        /// The day's request cap is reached: no request is sent, and the episode waits or stops.
        case dailyCap
    }

    /// The one routing decision an attempt makes: its journalled digest and its
    /// run both read this value, so a setting changed mid-run cannot split them.
    struct LabelledAttemptRoute: Sendable {
        /// Nil keeps the local classifier.
        var routing: LabelledRouting?
        /// Model, level and prompt version the labelled path will use; nil when local.
        var provenance: LabelledRunProvenance?
    }

    /// Shared by ``prepare`` and ``prepareAgain``: local classifier, or transcript → label → cut.
    ///
    /// `route` is the attempt's ``labelledAttemptRoute(episode:policy:)``.
    /// `deferral` names the running generation a labelled failure may park; nil
    /// (``prepareAgain``, or a run with no attempt) never defers.
    func runPreparationWorker(
        episode: PodcastEpisode,
        audioURL: URL,
        preparedURL: URL,
        sourceHash: String,
        policy: PodcastPreparationPolicySnapshot,
        profileSnapshot: PodcastAdProfileSnapshot?,
        emitLabellerCues: Bool,
        route: LabelledAttemptRoute,
        deferral: LabelledDeferralContext?,
        onStatus: @escaping @Sendable (PodcastPreparationProgress) -> Void
    ) async throws -> PreparationWorkerRun {
        if let services = labelling, let routing = route.routing, let provenance = route.provenance {
            return try await runLabelledPreparation(
                episode: episode, audioURL: audioURL, preparedURL: preparedURL,
                sourceHash: sourceHash, policy: policy, profileSnapshot: profileSnapshot,
                services: services, routing: routing, provenance: provenance,
                deferral: deferral, onStatus: onStatus)
        }
        let request = try await workerRequest(
            episode: episode, audioURL: audioURL, preparedURL: preparedURL, sourceHash: sourceHash,
            policy: policy, profileSnapshot: profileSnapshot, emitLabellerCues: emitLabellerCues,
            onStatus: onStatus)
        let response = try await runner.run(request: request, onProgress: onStatus)
        return PreparationWorkerRun(payload: try Self.decode(response), labelledProvenance: nil)
    }

    /// Pure gate shared with ``LabelledPolicyDigestInForce``: nil keeps the local
    /// classifier; ``remote`` or ``dailyCap`` enters the labelled path.
    static func labelledRoutingDecision(
        isShadow: Bool,
        input: RemoteLabellingInput,
        context: RemoteLabellingContext
    ) -> LabelledRouting? {
        guard !isShadow else { return nil }
        switch RemoteLabellingPolicy.route(for: input, context: context) {
        case .remote: return .remote
        case .local(.dailyCapReached): return .dailyCap
        case .local: return nil
        }
    }

    /// Provenance folded into a labelled outcome; shared so digest-in-force cannot drift.
    static func labelledRunProvenance(preferences: AdLabellerPreferences) -> LabelledRunProvenance {
        LabelledRunProvenance(
            route: "remote",
            modelID: preferences.modelID,
            level: preferences.level,
            promptVersion: EpisodeLabeller.promptVersion
        )
    }

    /// Nil keeps the local classifier. Only the daily cap, of all the local reasons, enters
    /// the labelled path: it waits for midnight or stops there instead of falling back.
    private func labelledRouting(
        episode: PodcastEpisode,
        policy: PodcastPreparationPolicySnapshot,
        services: PodcastLabellingServices
    ) async -> LabelledRouting? {
        let preferences = services.preferences
        guard !preferences.isShadow,
              let feed = try? await store.podcastFeed(for: episode.feedID) else { return nil }
        let customTitle: String?
        do { customTitle = try await store.subscription(for: episode.feedID)?.displayName } catch { return nil }
        return Self.labelledRoutingDecision(
            isShadow: false,
            input: RemoteLabellingInput(
                feedID: episode.feedID.rawValue, feedURL: feed.canonicalURL, feedTitle: feed.title,
                customTitle: customTitle, audioURL: episode.enclosureURL, removeAds: policy.removeAds),
            context: RemoteLabellingContext(
                preferences: preferences, hasKey: services.keyStore.hasKey(), counter: services.counter))
    }

    /// Evaluates the gate once for an attempt and fixes the provenance it will run under.
    func labelledAttemptRoute(
        episode: PodcastEpisode,
        policy: PodcastPreparationPolicySnapshot
    ) async -> LabelledAttemptRoute {
        guard let services = labelling,
              let routing = await labelledRouting(episode: episode, policy: policy, services: services) else {
            return LabelledAttemptRoute(routing: nil, provenance: nil)
        }
        return LabelledAttemptRoute(
            routing: routing, provenance: Self.labelledRunProvenance(preferences: services.preferences))
    }

    private func runLabelledPreparation(
        episode: PodcastEpisode,
        audioURL: URL,
        preparedURL: URL,
        sourceHash: String,
        policy: PodcastPreparationPolicySnapshot,
        profileSnapshot: PodcastAdProfileSnapshot?,
        services: PodcastLabellingServices,
        routing: LabelledRouting,
        provenance: LabelledRunProvenance,
        deferral: LabelledDeferralContext?,
        onStatus: @escaping @Sendable (PodcastPreparationProgress) -> Void
    ) async throws -> PreparationWorkerRun {
        let feedTitle = (try? await store.podcastFeed(for: episode.feedID))?.title ?? ""
        var cached: LabelledTranscript?
        if let deferral {
            removeStaleCueFiles(for: deferral)
            cached = loadCueFile(for: deferral)
        }
        func original(_ reason: String) async throws -> PreparationWorkerRun {
            let payload = try await wholeOriginal(
                reason: reason, episode: episode, audioURL: audioURL, preparedURL: preparedURL,
                sourceHash: sourceHash, policy: policy, profileSnapshot: profileSnapshot, onStatus: onStatus)
            return PreparationWorkerRun(payload: payload, labelledProvenance: provenance)
        }
        do {
            let run: PreparationWorkerRun
            if routing == .dailyCap {
                let reason = try await settleLabellerHold(
                    .dailyCap, transcript: nil, deferral: deferral, services: services, onStatus: onStatus)
                run = try await original(stopLabelledPath(reason, onStatus: onStatus))
            } else {
                run = try await labelledLoop(
                    episode: episode, audioURL: audioURL, preparedURL: preparedURL, sourceHash: sourceHash,
                    policy: policy, profileSnapshot: profileSnapshot, services: services, feedTitle: feedTitle,
                    provenance: provenance, deferral: deferral, cached: cached, original: original,
                    onStatus: onStatus)
            }
            if let deferral { removeCueFile(for: deferral) }
            return run
        } catch let waiting as PodcastPreparationError where waiting.isLabellerWaiting {
            throw waiting
        } catch {
            if let deferral { removeCueFile(for: deferral) }
            throw error
        }
    }

    private func labelledLoop(
        episode: PodcastEpisode,
        audioURL: URL,
        preparedURL: URL,
        sourceHash: String,
        policy: PodcastPreparationPolicySnapshot,
        profileSnapshot: PodcastAdProfileSnapshot?,
        services: PodcastLabellingServices,
        feedTitle: String,
        provenance: LabelledRunProvenance,
        deferral: LabelledDeferralContext?,
        cached: LabelledTranscript?,
        original: (String) async throws -> PreparationWorkerRun,
        onStatus: @escaping @Sendable (PodcastPreparationProgress) -> Void
    ) async throws -> PreparationWorkerRun {
        var cached = cached
        var mismatchRestarts = 0
        while true {
            do {
                let payload = try await labelledAttempt(
                    episode: episode, audioURL: audioURL, preparedURL: preparedURL,
                    sourceHash: sourceHash, policy: policy, profileSnapshot: profileSnapshot,
                    services: services, feedTitle: feedTitle, provenance: provenance, cached: cached,
                    onStatus: onStatus)
                return PreparationWorkerRun(payload: payload, labelledProvenance: provenance)
            } catch let failed as LabelledAttemptFailure {
                let reason = try await settleLabellerHold(
                    .failure(failed.failure), transcript: failed.transcript, deferral: deferral,
                    services: services, onStatus: onStatus)
                return try await original(stopLabelledPath(reason, onStatus: onStatus))
            } catch let error as PodcastPreparationError {
                guard case .workerFailed(let code, _) = error, code == Self.labelledCuesMismatchCode else { throw error }
                // A reused cue list that no longer matches is dropped with its file.
                cached = nil
                if let deferral { removeCueFile(for: deferral) }
                if mismatchRestarts == 0 {
                    mismatchRestarts = 1
                    continue
                }
                return try await original("labelled cues digest mismatch")
            }
        }
    }

    private func labelledAttempt(
        episode: PodcastEpisode,
        audioURL: URL,
        preparedURL: URL,
        sourceHash: String,
        policy: PodcastPreparationPolicySnapshot,
        profileSnapshot: PodcastAdProfileSnapshot?,
        services: PodcastLabellingServices,
        feedTitle: String,
        provenance: LabelledRunProvenance,
        cached: LabelledTranscript?,
        onStatus: @escaping @Sendable (PodcastPreparationProgress) -> Void
    ) async throws -> WorkerPayload {
        let transcript: LabelledTranscript
        if let cached {
            transcript = cached
        } else {
            let stage = try await runTranscriptStage(
                episode: episode, audioURL: audioURL, preparedURL: preparedURL, sourceHash: sourceHash,
                policy: policy, profileSnapshot: profileSnapshot, onStatus: onStatus)
            transcript = try Self.readLabelledTranscript(stage)
        }
        let cues = transcript.cues
        onStatus(PodcastPreparationProgress(
            stage: "ads.label.start",
            detail: "\(cues.count) transcript cues",
            evidence: try? PreparationEvidence(kind: "labeller-request", fields: [
                "cueCount": String(cues.count),
                "modelID": provenance.modelID,
                "level": provenance.level,
            ])))
        let reply: LabellerReply
        do {
            let response = try await services.sender.send(
                LabellerRequest(
                    prompt: EpisodeLabeller.prompt(showTitle: feedTitle, cues: cues),
                    modelID: provenance.modelID,
                    reasoningLevel: provenance.level),
                onRequestStarted: { services.counter.record() },
                onProgress: { _ in })
            // The provider answered, so it is not paused whatever the answer says.
            services.preferences.clearProviderPause()
            switch EpisodeLabeller.parse(reply: response.text, cues: cues, duration: transcript.durationSeconds) {
            case .success(let parsed): reply = parsed
            case .failure(let failure): throw LabelledAttemptFailure(failure: failure, transcript: transcript)
            }
        } catch let error as LabelledAttemptFailure {
            throw error
        } catch let error as PodcastPreparationError {
            throw error
        } catch let failure as LabellerFailure {
            throw LabelledAttemptFailure(failure: failure, transcript: transcript)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw LabelledAttemptFailure(failure: .temporary, transcript: transcript)
        }
        onStatus(PodcastPreparationProgress(
            stage: "ads.label.complete",
            detail: "\(reply.breaks.count) breaks, \(reply.rejected.count) rejected",
            evidence: try? PreparationEvidence(kind: "labeller-result", fields: [
                "breaks": String(reply.breaks.count),
                "rejected": String(reply.rejected.count),
            ])))
        let cutFields = try await workerRequestFields(
            episode: episode, audioURL: audioURL, preparedURL: preparedURL, sourceHash: sourceHash,
            policy: policy, profileSnapshot: profileSnapshot, emitLabellerCues: false, onStatus: onStatus)
        var cutRequest = cutFields
        cutRequest["adStage"] = "cut"
        cutRequest["removeAds"] = true
        cutRequest["labelledBreaks"] = reply.breaks.map { breakValue -> [String: Any] in
            [
                "start": breakValue.startSeconds,
                "end": breakValue.endSeconds,
                "kind": breakValue.kind.rawValue,
                "label": breakValue.label.rawValue,
                "advertisers": breakValue.advertisers,
            ]
        }
        cutRequest["labellerCuesDigest"] = transcript.digest
        cutRequest["labellerModelID"] = provenance.modelID
        cutRequest["labellerLevel"] = provenance.level
        cutRequest["labellerPromptVersion"] = provenance.promptVersion
        let cutData = try JSONSerialization.data(withJSONObject: cutRequest)
        let payload = try Self.decode(try await runner.run(request: cutData, onProgress: onStatus))
        reportLeftInBreaks(
            workerLeftIn: payload.labelledLeftIn, rejected: reply.rejected, cues: cues, onStatus: onStatus)
        return payload
    }

    private func runTranscriptStage(
        episode: PodcastEpisode,
        audioURL: URL,
        preparedURL: URL,
        sourceHash: String,
        policy: PodcastPreparationPolicySnapshot,
        profileSnapshot: PodcastAdProfileSnapshot?,
        onStatus: @escaping @Sendable (PodcastPreparationProgress) -> Void
    ) async throws -> TranscriptStagePayload {
        var fields = try await workerRequestFields(
            episode: episode, audioURL: audioURL, preparedURL: preparedURL, sourceHash: sourceHash,
            policy: policy, profileSnapshot: profileSnapshot, emitLabellerCues: false, onStatus: onStatus)
        fields["adStage"] = "transcript"
        let data = try JSONSerialization.data(withJSONObject: fields)
        let response = try await runner.run(request: data, onProgress: onStatus)
        return try Self.decodeTranscriptStage(response)
    }

    /// One more ordinary worker call with ad removal off, then mark the outcome uncertain
    /// with `reason` as the warning's explanation.
    private func wholeOriginal(
        reason: String,
        episode: PodcastEpisode,
        audioURL: URL,
        preparedURL: URL,
        sourceHash: String,
        policy: PodcastPreparationPolicySnapshot,
        profileSnapshot: PodcastAdProfileSnapshot?,
        onStatus: @escaping @Sendable (PodcastPreparationProgress) -> Void
    ) async throws -> WorkerPayload {
        let fallbackPolicy = PodcastPreparationPolicySnapshot(
            transcriptPolicy: policy.transcriptPolicy,
            removeAds: false,
            removeSelfPromotion: policy.removeSelfPromotion)
        let request = try await workerRequest(
            episode: episode, audioURL: audioURL, preparedURL: preparedURL, sourceHash: sourceHash,
            policy: fallbackPolicy, profileSnapshot: nil, emitLabellerCues: false, onStatus: onStatus)
        var payload = try Self.decode(try await runner.run(request: request, onProgress: onStatus))
        payload.adRemovalOutcome = "uncertain"
        payload.warning = "original audio includes ads: \(reason)"
        payload.audioChanged = false
        payload.adSegments = []
        payload.removedSeconds = 0
        payload.keepIntervals = []
        payload.silenceTrims = []
        payload.timeline = try PreparationStatus.PreparationTimeline(removed: [], kept: [])
        onStatus(PodcastPreparationProgress(
            stage: "ads.uncertain",
            detail: payload.warning ?? reason))
        return payload
    }

    private func reportLeftInBreaks(
        workerLeftIn: [LabelledLeftInBreak],
        rejected: [RejectedBreak],
        cues: [LabellerCue],
        onStatus: @escaping @Sendable (PodcastPreparationProgress) -> Void
    ) {
        var ordinal = 0
        func report(start: Double?, end: Double?, reason: String) {
            ordinal += 1
            var fields = ["ordinal": String(ordinal), "reason": reason]
            if let start { fields["startSeconds"] = String(format: "%.3f", start) }
            if let end { fields["endSeconds"] = String(format: "%.3f", end) }
            let clock: (Double) -> String = { seconds in
                guard seconds.isFinite, seconds >= 0, seconds <= 7 * 24 * 60 * 60 else { return "unknown" }
                let total = Int(seconds.rounded())
                return String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
            }
            let span: String
            if let start, let end {
                span = "\(clock(start))–\(clock(end))"
            } else {
                span = "unknown span"
            }
            onStatus(PodcastPreparationProgress(
                stage: "ads.left-in.\(ordinal)",
                detail: "\(span) · left in · \(reason)",
                evidence: try? PreparationEvidence(kind: "advertisement-left-in", fields: fields)))
        }
        for entry in workerLeftIn {
            report(start: entry.startSeconds, end: entry.endSeconds, reason: entry.reason)
        }
        let cueIndex = Dictionary(cues.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for entry in rejected {
            let start = cueIndex[entry.startSegment]?.start
            let end = cueIndex[entry.endSegment]?.end
            report(start: start, end: end, reason: Self.leftInReason(for: entry.reason))
        }
    }

    static func leftInReason(for reason: RejectedBreakReason) -> String {
        switch reason {
        case .outsideEpisode: "out-of-range"
        case .unknownCueID, .invertedRange, .tooLong, .unknownKindOrLabel: "malformed"
        }
    }

    /// A cue list that fails its digest is a local fault, not a provider failure: it
    /// takes the cue-mismatch path (one restart, then the whole original), never a
    /// provider wait.
    static func decodeLabellerCues(_ data: Data, expectedDigest: String) throws -> [LabellerCue] {
        guard let cues = try? JSONDecoder().decode([LabellerCue].self, from: data),
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == expectedDigest else {
            throw cueMismatch()
        }
        return cues
    }

    /// The worker's cue file as one verified value, keeping the bytes the digest covers.
    static func readLabelledTranscript(_ stage: TranscriptStagePayload) throws -> LabelledTranscript {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: stage.labellerCuesPath)) else {
            throw cueMismatch()
        }
        return LabelledTranscript(
            cues: try decodeLabellerCues(data, expectedDigest: stage.labellerCuesDigest),
            cuesData: data, digest: stage.labellerCuesDigest, durationSeconds: stage.durationSeconds)
    }

    private static func cueMismatch() -> PodcastPreparationError {
        .workerFailed(code: labelledCuesMismatchCode, message: "cue file does not match labellerCuesDigest")
    }
}
