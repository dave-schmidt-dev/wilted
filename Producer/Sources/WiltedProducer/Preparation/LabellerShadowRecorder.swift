import CryptoKit
import Foundation

/// Sends one labelling request on behalf of ``LabellerShadowRecorder``. The
/// shape is exactly ``LabellerClient``'s `send`, so the real client conforms
/// with an empty extension and tests can stub it.
public protocol LabellerSending: Sendable {
    /// Performs one labelling request. `onRequestStarted` fires exactly once,
    /// immediately before the HTTP request starts, including for calls that
    /// then fail.
    func send(
        _ request: LabellerRequest,
        onRequestStarted: @escaping @Sendable () -> Void,
        onProgress: @escaping @Sendable (LabellerProgress) -> Void
    ) async throws -> LabellerResponse
}

/// The real client already has exactly this shape.
extension LabellerClient: LabellerSending {}

/// Records what the online labeller would have cut beside what today's engine
/// did cut, for a later comparison report.
///
/// Shadow runs only after the pipeline has committed: it holds no work ticket
/// and no GPU lock, is never awaited by the pipeline, and never changes audio,
/// tickets, journal state or outcomes. Every write failure is swallowed, and
/// records carry no transcript text, no prompt, no raw reply and no key.
public actor LabellerShadowRecorder {
    /// One span of audio in seconds, on the original clock.
    public struct ShadowSpan: Equatable, Sendable {
        public var start: Double
        public var end: Double

        public init(start: Double, end: Double) {
            self.start = start
            self.end = end
        }
    }

    /// One committed episode offered to the shadow labeller.
    public struct ShadowInput: Sendable {
        public var episodeID: String
        public var feedID: String
        public var feedURL: URL?
        public var feedTitle: String
        /// The owner's own name for the show; used only to keep it local, never in the prompt.
        public var feedCustomTitle: String?
        public var audioURL: URL?
        /// The episode's duration in seconds, on the original clock the cue
        /// file shares.
        public var durationSeconds: Double
        /// The cue file the worker exported, and its SHA-256 hex digest. Both
        /// are absent when the request did not ask for cues.
        public var cuesPath: String?
        public var cuesDigest: String?
        /// The engine's committed outcome string.
        public var engineOutcome: String
        /// The spans the engine cut, in seconds on the original clock.
        public var engineCutSpans: [ShadowSpan]
        /// Where the input came from: nil on the live path, "backfill" for the
        /// label-only backfill over stored transcripts.
        public var source: String?
        /// The engine version that produced the committed cut, when the
        /// journal records one. Nil on the live path.
        public var engineVersion: String?
        /// Whether the episode was admitted with ad removal on. Off keeps it local.
        public var removeAds: Bool

        public init(
            episodeID: String,
            feedID: String,
            feedURL: URL?,
            feedTitle: String,
            feedCustomTitle: String? = nil,
            audioURL: URL?,
            durationSeconds: Double,
            cuesPath: String?,
            cuesDigest: String?,
            engineOutcome: String,
            engineCutSpans: [ShadowSpan],
            source: String? = nil,
            engineVersion: String? = nil,
            removeAds: Bool = true
        ) {
            self.episodeID = episodeID
            self.feedID = feedID
            self.feedURL = feedURL
            self.feedTitle = feedTitle
            self.feedCustomTitle = feedCustomTitle
            self.audioURL = audioURL
            self.durationSeconds = durationSeconds
            self.cuesPath = cuesPath
            self.cuesDigest = cuesDigest
            self.engineOutcome = engineOutcome
            self.engineCutSpans = engineCutSpans
            self.source = source
            self.engineVersion = engineVersion
            self.removeAds = removeAds
        }
    }

    /// What one awaited labelling call produced. ``schedule(_:)`` reports
    /// nothing; this is how the backfill counts its batch.
    public enum LabelOutcome: Equatable, Sendable {
        /// A comparison record was written.
        case recorded
        /// The attempt ran and failed; the kind is a ``LabellerFailure`` kind
        /// or `cuesUnavailable`.
        case failed(kind: String)
        /// The policy kept the episode local; nothing was written.
        case notRouted(RemoteLabellingLocalReason)
        /// Shadow is not active; nothing was written.
        case inactive
        /// The task was cancelled; nothing was written.
        case cancelled
    }

    /// The record schema this version writes.
    private static let schemaVersion = 1
    /// The failure kind recorded when the cue file is missing, unreadable or
    /// does not match its digest.
    static let cuesUnavailableKind = "cuesUnavailable"
    /// One line per shadow attempt, beside the records.
    public static let attemptsFileName = "attempts.jsonl"

    private let preferences: AdLabellerPreferences
    private let counter: LabellerRequestCounter
    private let keyStore: any LabellerKeyStoring
    private let sender: any LabellerSending
    private let transport: String
    private let recordsDirectory: URL
    private let now: @Sendable () -> Date
    private var tasks: [UUID: Task<Void, Never>] = [:]

    /// - Parameters:
    ///   - preferences: the owner's labeller choices, including the shadow flag.
    ///   - counter: the daily HTTP request counter the route and retry consult.
    ///   - keyStore: where the provider key is kept; only `hasKey` is read here.
    ///   - sender: performs the labelling request.
    ///   - transport: the route that sends requests, written to records that reached the sender.
    ///   - recordsDirectory: where records and `attempts.jsonl` are written.
    ///   - now: the clock `recordedAt` and request timing are read from.
    public init(
        preferences: AdLabellerPreferences,
        counter: LabellerRequestCounter,
        keyStore: any LabellerKeyStoring,
        sender: any LabellerSending, transport: String = "direct",
        recordsDirectory: URL,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.preferences = preferences
        self.counter = counter
        self.keyStore = keyStore
        self.sender = sender
        self.transport = transport
        self.recordsDirectory = recordsDirectory
        self.now = now
    }

    /// Whether shadow is running at all: the owner's global switch is on and
    /// the shadow flag is on. While this is false nothing is exported, sent or
    /// written, so an install that never turned the feature on leaves no trace.
    private var isActive: Bool { preferences.isEnabled && preferences.isShadow }

    /// Whether the pipeline should ask the worker for a cue export.
    public var wantsCues: Bool { isActive }

    /// Offers one committed episode to the shadow labeller. Returns at once:
    /// the cue file is read and its digest checked before returning (the next
    /// preparation overwrites it), and the request, if any, runs in a tracked
    /// background task the pipeline never awaits.
    public func schedule(_ input: ShadowInput) {
        guard isActive else { return }
        switch route(for: input) {
        case .local(let reason):
            var fields = commonFields(input, route: "local")
            fields["routeReason"] = reason.rawValue
            writeRecord(fields, episodeID: input.episodeID)
            appendAttempt(episodeID: input.episodeID, outcome: "local")
        case .remote:
            // Read now, not in the task: the next preparation overwrites the file.
            guard let cues = readCues(input) else {
                var fields = remoteFields(input, cueCount: nil, requestSeconds: 0, requestCount: 0)
                fields["failureKind"] = Self.cuesUnavailableKind
                writeRecord(fields, episodeID: input.episodeID)
                appendAttempt(episodeID: input.episodeID, outcome: Self.cuesUnavailableKind)
                return
            }
            let id = UUID()
            tasks[id] = Task { await run(input: input, cues: cues, attemptID: id) }
        }
    }

    /// Labels one episode in the caller's task and returns what happened.
    ///
    /// Unlike ``schedule(_:)`` this writes no record and no attempt line when
    /// shadow is inactive or the policy keeps the episode local: the backfill
    /// that awaits it counts skips itself. Every other outcome is recorded
    /// exactly as `schedule` records it. A cancelled task writes nothing and
    /// reports ``LabelOutcome/cancelled``.
    public func label(_ input: ShadowInput) async -> LabelOutcome {
        guard isActive else { return .inactive }
        if case .local(let reason) = route(for: input) { return .notRouted(reason) }
        guard let cues = readCues(input) else {
            var fields = remoteFields(input, cueCount: nil, requestSeconds: 0, requestCount: 0)
            fields["failureKind"] = Self.cuesUnavailableKind
            writeRecord(fields, episodeID: input.episodeID)
            appendAttempt(episodeID: input.episodeID, outcome: Self.cuesUnavailableKind)
            return .failed(kind: Self.cuesUnavailableKind)
        }
        return await perform(input: input, cues: cues)
    }

    /// The policy's reason for keeping this episode local right now, or nil
    /// when it would be sent. Writes nothing.
    public func localReason(for input: ShadowInput) -> RemoteLabellingLocalReason? {
        if case .local(let reason) = route(for: input) { return reason }
        return nil
    }

    /// Whether a readable record already exists for the episode that went
    /// remote and produced a comparison. Such an episode needs no second
    /// request; one whose record failed may be labelled again.
    public func hasLabelledRecord(episodeID: String) -> Bool {
        let url = recordsDirectory.appendingPathComponent(Self.recordFileName(for: episodeID))
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["route"] as? String) == "remote",
              object["failureKind"] == nil else { return false }
        return true
    }

    /// How many labelling requests today's cap still allows.
    public var requestsRemaining: Int {
        max(0, counter.cap - counter.count)
    }

    /// Cancels every running shadow task. A cancelled task writes nothing.
    public func cancelAll() {
        for task in tasks.values { task.cancel() }
    }

    /// Awaits every running shadow task. For tests; production code never
    /// waits for shadow.
    public func waitForIdle() async {
        for task in Array(tasks.values) { _ = await task.value }
    }

    /// The record file name for one episode: a SHA-256 of the episode ID, so
    /// no title or URL appears in a file name.
    public static func recordFileName(for episodeID: String) -> String {
        sha256Hex(Data(episodeID.utf8)) + ".json"
    }

    /// Token counts across both requests of a retried attempt; a count neither
    /// reply reported stays nil.
    static func summed(_ first: LabellerUsage, _ second: LabellerUsage) -> LabellerUsage {
        func add(_ a: Int?, _ b: Int?) -> Int? { (a == nil && b == nil) ? nil : (a ?? 0) + (b ?? 0) }
        return LabellerUsage(promptTokens: add(first.promptTokens, second.promptTokens),
                             completionTokens: add(first.completionTokens, second.completionTokens),
                             reasoningTokens: add(first.reasoningTokens, second.reasoningTokens))
    }

    /// The model's advertiser names as a record keeps them: at most 8 names of
    /// at most 60 characters on one line each, so a reply cannot carry a stretch
    /// of transcript into the records.
    static func recordedAdvertisers(_ names: [String]) -> [String] {
        names.prefix(8).compactMap { name in
            let oneLine = name.components(separatedBy: .newlines).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return oneLine.isEmpty ? nil : String(oneLine.prefix(60))
        }
    }

    // MARK: One attempt

    /// The policy's route for one input, against the owner's current choices.
    private func route(for input: ShadowInput) -> RemoteLabellingRoute {
        RemoteLabellingPolicy.route(
            for: RemoteLabellingInput(feedID: input.feedID, feedURL: input.feedURL, feedTitle: input.feedTitle,
                                      customTitle: input.feedCustomTitle, audioURL: input.audioURL,
                                      removeAds: input.removeAds),
            context: RemoteLabellingContext(preferences: preferences, hasKey: keyStore.hasKey(),
                                             counter: counter))
    }

    /// Reads the cue file and checks its digest. Nil when the file is
    /// missing, unreadable, undecodable or does not match its digest.
    private func readCues(_ input: ShadowInput) -> [LabellerCue]? {
        guard let path = input.cuesPath, let expected = input.cuesDigest,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let cues = try? JSONDecoder().decode([LabellerCue].self, from: data),
              Self.sha256Hex(data) == expected else { return nil }
        return cues
    }

    /// `schedule`'s tracked wrapper around the shared core.
    private func run(input: ShadowInput, cues: [LabellerCue], attemptID: UUID) async {
        defer { tasks[attemptID] = nil }
        _ = await perform(input: input, cues: cues)
    }

    /// One shadow attempt: build the prompt, send once, parse, retry at most
    /// once on an unusable answer while the daily cap allows it, then record
    /// the outcome. A cancelled attempt writes nothing.
    ///
    /// The one core `schedule`'s background task and `label`'s awaited call
    /// share.
    private func perform(input: ShadowInput, cues: [LabellerCue]) async -> LabelOutcome {
        guard !Task.isCancelled else { return .cancelled }
        let counter = self.counter
        let sender = self.sender
        let request = LabellerRequest(
            prompt: EpisodeLabeller.prompt(showTitle: input.feedTitle, cues: cues),
            modelID: preferences.modelID,
            reasoningLevel: preferences.level
        )
        let tally = RequestTally()
        let started = now()
        func sendOnce() async throws -> LabellerResponse {
            try await sender.send(request, onRequestStarted: { tally.add(); counter.record() },
                                 onProgress: { tally.note($0.failure) })
        }
        do {
            let first = try await sendOnce()
            var usage = first.usage
            var reply = EpisodeLabeller.parse(reply: first.text, cues: cues, duration: input.durationSeconds)
            if case .failure(.unusableAnswer) = reply, !counter.hasReachedCap, !Task.isCancelled {
                let second = try await sendOnce()
                usage = Self.summed(usage, second.usage)
                reply = EpisodeLabeller.parse(reply: second.text, cues: cues, duration: input.durationSeconds)
            }
            let requestSeconds = now().timeIntervalSince(started)
            guard !Task.isCancelled else { return .cancelled }
            switch reply {
            case .success(let parsed):
                var fields = remoteFields(input, cueCount: cues.count, requestSeconds: requestSeconds,
                                          requestCount: tally.value)
                fields["proposedBreaks"] = parsed.breaks.map { value in
                    ["start": value.startSeconds, "end": value.endSeconds, "startCue": value.startCue,
                     "endCue": value.endCue, "kind": value.kind.rawValue, "label": value.label.rawValue,
                     "advertisers": Self.recordedAdvertisers(value.advertisers)] as [String: Any]
                }
                fields["rejectedBreaks"] = parsed.rejected.map { value in
                    ["startSegment": value.startSegment, "endSegment": value.endSegment,
                     "reason": value.reason.rawValue] as [String: Any]
                }
                if let tokens = usage.promptTokens { fields["promptTokens"] = tokens }
                if let tokens = usage.completionTokens { fields["completionTokens"] = tokens }
                if let tokens = usage.reasoningTokens { fields["reasoningTokens"] = tokens }
                fields["transport"] = transport
                writeRecord(fields, episodeID: input.episodeID)
                appendAttempt(episodeID: input.episodeID, outcome: "recorded", transport: transport)
                return .recorded
            case .failure(let failure):
                writeRecord(failureFields(input, kind: failure.kind, cueCount: cues.count,
                                          requestSeconds: requestSeconds, requestCount: tally.value),
                            episodeID: input.episodeID)
                appendAttempt(episodeID: input.episodeID, outcome: failure.kind, transport: transport)
                return .failed(kind: failure.kind)
            }
        } catch is CancellationError {
            return .cancelled
        } catch let failure as LabellerFailure {
            guard !Task.isCancelled else { return .cancelled }
            recordFailure(input, kind: failure.kind, cueCount: cues.count, started: started, tally: tally,
                          detail: tally.detail)
            return .failed(kind: failure.kind)
        } catch {
            guard !Task.isCancelled else { return .cancelled }
            recordFailure(input, kind: LabellerFailure.temporary.kind, cueCount: cues.count,
                          started: started, tally: tally)
            return .failed(kind: LabellerFailure.temporary.kind)
        }
    }

    /// Records a failed attempt with the request timing measured so far.
    private func recordFailure(_ input: ShadowInput, kind: String, cueCount: Int,
                               started: Date, tally: RequestTally, detail: LabellerFailureDetail? = nil) {
        var fields = failureFields(input, kind: kind, cueCount: cueCount,
                                   requestSeconds: now().timeIntervalSince(started), requestCount: tally.value)
        if let detail {
            fields["httpStatus"] = detail.status
            if let type = detail.errorType { fields["providerErrorType"] = type }
        }
        writeRecord(fields, episodeID: input.episodeID)
        appendAttempt(episodeID: input.episodeID, outcome: kind, detail: detail, transport: transport)
    }

    // MARK: Records

    /// The fields every record carries, whatever its route. `source` and
    /// `engineVersion` appear only when the input names them, so live
    /// records stay exactly the bytes they always were.
    private func commonFields(_ input: ShadowInput, route: String) -> [String: Any] {
        var fields: [String: Any] = [
            "schemaVersion": Self.schemaVersion,
            "recordedAt": Self.timestamp(now()),
            "episodeID": input.episodeID,
            "feedID": input.feedID,
            "route": route,
            "engineOutcome": input.engineOutcome,
            "engineCutSpans": input.engineCutSpans.map { ["start": $0.start, "end": $0.end] },
        ]
        if let source = input.source { fields["source"] = source }
        if let engineVersion = input.engineVersion { fields["engineVersion"] = engineVersion }
        return fields
    }

    /// The fields every remote record carries, whatever its outcome.
    private func remoteFields(_ input: ShadowInput, cueCount: Int?, requestSeconds: Double,
                              requestCount: Int) -> [String: Any] {
        var fields = commonFields(input, route: "remote")
        fields["modelID"] = preferences.modelID
        fields["level"] = preferences.level
        fields["promptVersion"] = EpisodeLabeller.promptVersion
        fields["requestSeconds"] = requestSeconds
        fields["requestCount"] = requestCount
        if let digest = input.cuesDigest { fields["cuesDigest"] = digest }
        if let cueCount { fields["cueCount"] = cueCount }
        return fields
    }

    /// A remote record whose attempt produced no comparison.
    private func failureFields(_ input: ShadowInput, kind: String, cueCount: Int?,
                               requestSeconds: Double, requestCount: Int) -> [String: Any] {
        var fields = remoteFields(input, cueCount: cueCount, requestSeconds: requestSeconds,
                                  requestCount: requestCount)
        fields["failureKind"] = kind
        fields["transport"] = transport
        return fields
    }

    /// Writes one record, replacing any earlier record for the episode.
    private func writeRecord(_ fields: [String: Any], episodeID: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: fields,
                                                    options: [.prettyPrinted, .sortedKeys]) else { return }
        do {
            try FileManager.default.createDirectory(at: recordsDirectory, withIntermediateDirectories: true)
            try data.write(to: recordsDirectory.appendingPathComponent(Self.recordFileName(for: episodeID)),
                           options: .atomic)
        } catch {
            // Swallowed: shadow must never throw into the pipeline.
        }
    }

    /// Appends one line per shadow attempt: timestamp, episode ID, outcome kind.
    private func appendAttempt(episodeID: String, outcome: String, detail: LabellerFailureDetail? = nil,
                               transport: String? = nil) {
        var entry: [String: Any] = ["timestamp": Self.timestamp(now()), "episodeID": episodeID, "outcome": outcome]
        if let transport { entry["transport"] = transport }
        if let detail {
            entry["httpStatus"] = detail.status
            if let type = detail.errorType { entry["providerErrorType"] = type }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: .sortedKeys) else { return }
        var line = data
        line.append(0x0A)
        do {
            try FileManager.default.createDirectory(at: recordsDirectory, withIntermediateDirectories: true)
            let url = recordsDirectory.appendingPathComponent(Self.attemptsFileName)
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: url, options: .atomic)
            }
        } catch {
            // Swallowed: shadow must never throw into the pipeline.
        }
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    /// Counts HTTP requests across one shadow attempt. `onRequestStarted`
    /// fires on the sender's thread, so the count is lock-protected.
    private final class RequestTally: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var lastDetail: LabellerFailureDetail?

        func note(_ detail: LabellerFailureDetail?) {
            guard let detail else { return }
            lock.withLock { lastDetail = detail }
        }

        var detail: LabellerFailureDetail? { lock.withLock { lastDetail } }

        func add() {
            lock.lock()
            count += 1
            lock.unlock()
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }
}
