import CryptoKit
import Foundation
import Testing
import WiltedDomain
@testable import WiltedProducer

extension PodcastPreparationPipelineTests {
    // MARK: Fixtures

    static let itemID = try! ItemID(rawValue: "item-" + String(repeating: "4", count: 64))
    static let revisionID = try! RevisionID.derive(downloadedAudioContentHash: Fixture.contentHash(Data("x".utf8)))

    static func payload(text: String?) -> PodcastPreparationPipeline.WorkerPayload {
        PodcastPreparationPipeline.WorkerPayload(
            timing: .none, sourceTiming: .none, cues: [], text: text, languageCode: "en",
            audioPath: "/tmp/a.mp3", audioChanged: false, durationSeconds: nil,
            adSegments: [], removedSeconds: 0, keepIntervals: [],
            adRemovalOutcome: "disabled",
            timeline: try! PreparationStatus.PreparationTimeline(removed: [], kept: [])
        )
    }
}

final class StatusLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(String, String, Double?)] = []

    func append(_ stage: String, detail: String = "", fraction: Double? = nil) {
        lock.lock(); recorded.append((stage, detail, fraction)); lock.unlock()
    }

    var stages: [String] { lock.lock(); defer { lock.unlock() }; return recorded.map(\.0) }
    var entries: [(stage: String, detail: String, fraction: Double?)] {
        lock.lock(); defer { lock.unlock() }; return recorded.map { (stage: $0.0, detail: $0.1, fraction: $0.2) }
    }
    var fractions: [Double] { lock.lock(); defer { lock.unlock() }; return recorded.compactMap(\.2) }
}

/// Stands in for the Python worker, and records what it was asked to do.
///
/// A request without `adStage` asks for no ad removal and gets a `disabled`
/// report; one that asks for ad removal without a labelled stage fails the
/// test. On the labelled path it answers both stages: `transcript` exports a
/// cue list in which each configured advertisement is one marked cue, and
/// `cut` applies the configured response once the labelled breaks match those
/// advertisements exactly.
actor WorkerStub: PodcastPipelineRunning {
    /// The text of a cue that covers one configured advertisement.
    static let advertisementCueText = "Invented sponsor read."
    static let programmeCueText = "Invented programme talk."

    private let response: [String: Any]
    private let writesCutAudio: Data?
    private let progress: [PodcastPreparationProgress]
    private var requests: [Data] = []
    private let codeRevisionValue: String?

    init(response: [String: Any], writesCutAudio: Data? = nil,
         progress: [PodcastPreparationProgress] = [PodcastPreparationProgress(stage: "worker.start")],
         codeRevision: String? = nil) {
        self.response = response
        self.writesCutAudio = writesCutAudio
        self.progress = progress
        self.codeRevisionValue = codeRevision
    }

    func codeRevision() async -> String? { codeRevisionValue }

    /// A function, not a stored property: `[String: Any]` is not `Sendable`,
    /// so a static constant of it is a concurrency error.
    static func cleanAudit() -> [String: Any] {
        ["classifierRequests": 3, "classifierValidRequests": 3, "classifierInvalidRequests": 0,
         "exhaustedSingletonLineages": 0, "modelRequests": 3, "modelFailures": 0,
         "experimentalRequests": 0, "unresolvedIds": [Int](), "candidates": [[String: Any]](),
         "incompleteError": NSNull()]
    }

    /// The labelled cut stage's audit, in the shape the labelled worker writes.
    static func labelledAudit(
        proposed: Int = 0, cut: Int = 0, incompleteError: String? = nil, warning: String? = nil,
        modelID: String = AdLabellerPreferences.defaultModelID,
        level: String = AdLabellerPreferences.defaultLevel,
        promptVersion: String = EpisodeLabeller.promptVersion
    ) -> [String: Any] {
        ["adEngine": "labelled", "breaksProposed": proposed, "breaksCut": cut, "breaksLeftIn": 0,
         "leftIn": [[String: Any]](), "heldSpans": [[String: Any]](),
         "labellerModelID": modelID, "labellerLevel": level, "labellerPromptVersion": promptVersion,
         "incompleteError": incompleteError as Any? ?? NSNull(), "warning": warning as Any? ?? NSNull(),
         "unresolvedIds": [Int](), "modelRequests": 0, "modelFailures": 0, "experimentalRequests": 0,
         "classifierRequests": 0, "classifierValidRequests": 0, "classifierInvalidRequests": 0,
         "exhaustedSingletonLineages": 0, "candidates": [[String: Any]](),
         "declinedCommercialEvidenceSeeds": [[String: Any]]()]
    }

    /// Returned as bytes: a decoded `[String: Any]` cannot cross the actor
    /// boundary, and the caller wants to inspect it anyway. On the labelled
    /// path this is the `cut` stage's request.
    func lastRequest() -> Data? { requests.last }

    func allRequests() -> [Data] { requests }

    func run(
        request payload: Data,
        onProgress: @escaping @Sendable (PodcastPreparationProgress) -> Void
    ) async throws -> Data {
        let decoded = try JSONSerialization.jsonObject(with: payload) as? [String: Any] ?? [:]
        requests.append(payload)
        let stage = decoded["adStage"] as? String
        if stage == nil, decoded["removeAds"] as? Bool == true {
            Issue.record("the pipeline asked the worker to remove ads without a labelled stage")
            throw PodcastPreparationError.workerUnavailable("unstaged ad-removal request")
        }
        // The configured progress belongs to the run's last call, so a test
        // that counts it sees the same stages on either path.
        if stage == "transcript", response["ok"] as? Bool == true {
            return try JSONSerialization.data(withJSONObject: try transcriptStage(decoded))
        }
        progress.forEach(onProgress)
        var answer = response
        answer["protocolVersion"] = decoded["protocolVersion"] as? Int ?? 2
        if stage == "cut", answer["ok"] as? Bool == true {
            if let refusal = labelledCutRefusal(decoded, protocolVersion: answer["protocolVersion"]) {
                Issue.record("the labelled cut stage refused the configured response: \(refusal["code"] ?? "")")
                return try JSONSerialization.data(withJSONObject: refusal)
            }
            answer["adStage"] = "cut"
            if answer["report"] == nil { answer["report"] = labelledReport(decoded) }
        } else if answer["ok"] as? Bool == true, answer["report"] == nil, answer["adStage"] == nil {
            // An unstaged request asked for no ad removal, so the worker ran no
            // ad finder and reports none. Staged labelled replies carry their own shape.
            answer["report"] = ["outcome": "disabled", "rawNominations": [[String: Any]]()]
        }
        if let body = writesCutAudio, let outputPath = decoded["outputPath"] as? String {
            try body.write(to: URL(fileURLWithPath: outputPath))
            answer["audioPath"] = outputPath
        }
        return try JSONSerialization.data(withJSONObject: answer)
    }

    private var advertisementSpans: [(start: Double, end: Double)] {
        (response["adSegments"] as? [[String: Any]] ?? []).compactMap { ad in
            guard let start = ad["startSeconds"] as? Double, let end = ad["endSeconds"] as? Double else { return nil }
            return (start, end)
        }.sorted { $0.start < $1.start }
    }

    /// The original's length: the furthest point any configured interval
    /// reaches, else the cut audio's own length, else the fixture's twelve seconds.
    private var originalDuration: Double {
        let intervals = ["adSegments", "keepIntervals", "silenceTrims"].flatMap {
            response[$0] as? [[String: Any]] ?? []
        }
        let ends = intervals.compactMap { $0["endSeconds"] as? Double } + [response["durationSeconds"] as? Double ?? 0]
        let furthest = ends.max() ?? 0
        return furthest > 0 ? furthest : 12
    }

    /// Exports the cue list the labeller reads: one marked cue per configured
    /// advertisement, programme cues between them. The file sits where the
    /// real worker writes its own, outside the pipeline's `labeller-cues` folder.
    private func transcriptStage(_ request: [String: Any]) throws -> [String: Any] {
        let duration = originalDuration
        var cues: [LabellerCue] = []
        var cursor = 0.0
        for span in advertisementSpans {
            if span.start > cursor {
                cues.append(LabellerCue(id: cues.count, start: cursor, end: span.start, text: Self.programmeCueText))
            }
            cues.append(LabellerCue(id: cues.count, start: span.start, end: span.end, text: Self.advertisementCueText))
            cursor = max(cursor, span.end)
        }
        if duration > cursor {
            cues.append(LabellerCue(id: cues.count, start: cursor, end: duration, text: Self.programmeCueText))
        }
        let data = try JSONEncoder().encode(cues)
        // The pipeline always names its work directory; without one there is nowhere owned to write.
        guard let workDir = request["workDir"] as? String else { throw CocoaError(.fileNoSuchFile) }
        let directory = URL(fileURLWithPath: workDir)
            .appendingPathComponent("wilted-pipeline", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("labeller-cues.json")
        try data.write(to: url)
        return [
            "ok": true, "protocolVersion": request["protocolVersion"] as? Int ?? 2, "adStage": "transcript",
            "timing": "aligned", "durationSeconds": duration, "labellerCuesPath": url.path,
            "labellerCuesDigest": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
        ]
    }

    /// A worker error when the labelled cut cannot be the configured one: the
    /// breaks name other spans, or the test supplied an unlabelled report.
    private func labelledCutRefusal(_ request: [String: Any], protocolVersion: Any?) -> [String: Any]? {
        let asked = (request["labelledBreaks"] as? [[String: Any]] ?? []).compactMap { raw -> (Double, Double)? in
            guard let start = raw["start"] as? Double, let end = raw["end"] as? Double else { return nil }
            return (start, end)
        }
        let expected = advertisementSpans
        let matches = asked.count == expected.count && zip(asked, expected).allSatisfy {
            abs($0.0 - $1.start) < 1e-9 && abs($0.1 - $1.end) < 1e-9
        }
        let report = response["report"] as? [String: Any]
        let localReport = report != nil && (report?["audit"] as? [String: Any])?["adEngine"] as? String != "labelled"
        guard !matches || localReport else { return nil }
        return ["ok": false, "protocolVersion": protocolVersion ?? 2,
                "code": matches ? "stub-local-report-at-cut-stage" : "stub-labelled-breaks-mismatch",
                "message": "the labelled cut stage cannot apply the configured response"]
    }

    /// The labelled report a cut stage writes for the configured response.
    private func labelledReport(_ request: [String: Any]) -> [String: Any] {
        let segments = response["adSegments"] as? [[String: Any]] ?? []
        let changed = (response["audioChanged"] as? Bool) ?? (writesCutAudio != nil)
        let cut = changed && !segments.isEmpty ? segments.count : 0
        let proposed = cut > 0 ? cut : (request["labelledBreaks"] as? [[String: Any]] ?? []).count
        return [
            "outcome": cut > 0 ? "cut" : "noAds", "rawNominations": segments,
            "audit": Self.labelledAudit(
                proposed: proposed, cut: cut,
                modelID: request["labellerModelID"] as? String ?? AdLabellerPreferences.defaultModelID,
                level: request["labellerLevel"] as? String ?? AdLabellerPreferences.defaultLevel,
                promptVersion: request["labellerPromptVersion"] as? String ?? EpisodeLabeller.promptVersion),
        ]
    }
}

/// Wraps every fixture's worker: a request with ad removal on and no
/// labelled stage fails the test, so a test can reach a cut only through
/// the labelled path, whichever fake worker it uses.
struct LabelledOnlyRunner: PodcastPipelineRunning {
    let base: any PodcastPipelineRunning

    func codeRevision() async -> String? { await base.codeRevision() }

    func run(
        request payload: Data,
        onProgress: @escaping @Sendable (PodcastPreparationProgress) -> Void
    ) async throws -> Data {
        let decoded = (try? JSONSerialization.jsonObject(with: payload) as? [String: Any]) ?? [:]
        if decoded["removeAds"] as? Bool == true, decoded["adStage"] == nil {
            Issue.record("the pipeline sent an ad-removal request without a labelled stage")
            throw PodcastPreparationError.workerUnavailable("unstaged ad-removal request")
        }
        return try await base.run(request: payload, onProgress: onProgress)
    }
}

/// The labelled fixture's provider: answers at once with one must-cut sponsor
/// break for each cue the fake worker marked as an advertisement, so the
/// labelled cut lands on exactly the span the fake worker removes.
final class MarkedCueLabellerSender: LabellerSending, @unchecked Sendable {
    private let lock = NSLock()
    private var sent = 0

    var requestCount: Int { lock.withLock { sent } }

    func send(
        _ request: LabellerRequest,
        onRequestStarted: @escaping @Sendable () -> Void,
        onProgress: @escaping @Sendable (LabellerProgress) -> Void
    ) async throws -> LabellerResponse {
        lock.withLock { sent += 1 }
        onRequestStarted()
        let marked = request.prompt.split(separator: "\n").compactMap { line -> Int? in
            guard line.hasPrefix("#"), line.hasSuffix("] " + WorkerStub.advertisementCueText) else { return nil }
            return Int(line.dropFirst().prefix { $0.isNumber })
        }
        let breaks = marked.map {
            #"{"startSegment":\#($0),"endSegment":\#($0),"kind":"sponsor","label":"must-cut","advertisers":["Fizzbolt"]}"#
        }
        return LabellerResponse(text: #"{"breaks":["# + breaks.joined(separator: ",") + "]}", usage: LabellerUsage())
    }
}

/// A worker that lets a test look at the store mid-run, then fails.
actor ProbingWorker: PodcastPipelineRunning {
    private let probe: @Sendable () async throws -> Void

    init(probe: @escaping @Sendable () async throws -> Void) { self.probe = probe }

    func run(
        request payload: Data,
        onProgress: @escaping @Sendable (PodcastPreparationProgress) -> Void
    ) async throws -> Data {
        onProgress(PodcastPreparationProgress(stage: "worker.start"))
        try await probe()
        throw PodcastPreparationError.workerUnavailable("probe")
    }
}

/// Scripted multi-call worker for the labelled transcript → cut path.
actor LabelledStageWorker: PodcastPipelineRunning {
    typealias Handler = @Sendable (_ request: [String: Any], _ callIndex: Int) throws -> (response: [String: Any], cutAudio: Data?)

    private let handler: Handler
    private var requests: [Data] = []
    private var callIndex = 0

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func allRequests() -> [Data] { requests }

    func run(
        request payload: Data,
        onProgress: @escaping @Sendable (PodcastPreparationProgress) -> Void
    ) async throws -> Data {
        let decoded = try JSONSerialization.jsonObject(with: payload) as? [String: Any] ?? [:]
        requests.append(payload)
        let index = callIndex
        callIndex += 1
        onProgress(PodcastPreparationProgress(stage: "worker.start"))
        let answer = try handler(decoded, index)
        var response = answer.response
        response["protocolVersion"] = decoded["protocolVersion"] as? Int ?? 2
        if let body = answer.cutAudio, let outputPath = decoded["outputPath"] as? String {
            try body.write(to: URL(fileURLWithPath: outputPath))
            response["audioPath"] = outputPath
        }
        return try JSONSerialization.data(withJSONObject: response)
    }
}

/// Stands in for ``LabellerSending`` with scripted replies.
final class LabellerSenderStub: LabellerSending, @unchecked Sendable {
    enum Outcome: Sendable {
        case respond(LabellerResponse)
        case fail(LabellerFailure)
    }

    private let lock = NSLock()
    private var outcomes: [Outcome]
    private(set) var requests: [LabellerRequest] = []

    init(outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    var requestCount: Int { lock.withLock { requests.count } }

    func send(
        _ request: LabellerRequest,
        onRequestStarted: @escaping @Sendable () -> Void,
        onProgress: @escaping @Sendable (LabellerProgress) -> Void
    ) async throws -> LabellerResponse {
        let index = lock.withLock {
            requests.append(request)
            return requests.count - 1
        }
        onRequestStarted()
        let outcome = lock.withLock {
            outcomes.indices.contains(index) ? outcomes[index] : outcomes.last ?? .fail(.temporary)
        }
        switch outcome {
        case .respond(let response): return response
        case .fail(let failure): throw failure
        }
    }
}
