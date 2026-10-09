import CryptoKit
import Foundation
import Testing
@testable import WiltedProducer

@Suite("Local transcript summary service")
struct TranscriptSummaryServiceTests {
    @Test func publicModelIdentityHashesActualLocalFileAndRejectsMissingOrCancelledQueries() async throws {
        let fixture = try SummaryModelFixture()
        defer { fixture.remove() }
        let digest = try await TranscriptSummaryService.modelIdentity(at: fixture.model)
        #expect(digest == fixture.digest)
        await #expect(throws: TranscriptSummaryError.modelUnavailable) {
            try await TranscriptSummaryService.modelIdentity(at: fixture.root.appendingPathComponent("missing.gguf"))
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await TranscriptSummaryService.modelIdentity(at: fixture.model)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func configurationReusesVerifiedLocalSelectionAndExplicitOverride() {
        let explicit = URL(fileURLWithPath: "/synthetic/selected.gguf")
        #expect(TranscriptSummaryService.Configuration(modelURL: explicit).modelURL == explicit)
        let resolved = TranscriptSummaryService.Configuration.resolved(environment: ["LOCAL_MODELS_DIR": "/synthetic/models"])
        #expect(resolved.modelURL.path == "/synthetic/models/gemma-4-repaired/gemma-4-E4B_q4_0-it-2026-07-15-repaired.gguf")
        let defaultURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "models/gemma-4-repaired/gemma-4-E4B_q4_0-it-2026-07-15-repaired.gguf"
        )
        #expect(TranscriptSummaryService.Configuration.resolved(environment: [:]).modelURL == defaultURL)
        #expect(TranscriptSummaryService.Configuration.resolved(environment: ["LOCAL_MODELS_DIR": ""]).modelURL == defaultURL)
        #expect(TranscriptSummaryService.Configuration.resolved(environment: ["LOCAL_MODELS_DIR": "~/models"]).modelURL == defaultURL)
    }

    @Test func sendsExactTranscriptAndAcceptsWholeUnicodeScalarCoverage() async throws {
        let fixture = try SummaryModelFixture()
        defer { fixture.remove() }
        let runner = SummaryReplyRunner()
        let transcript = "cafe\u{301} 🌱水\r\n "
        #expect(transcript.unicodeScalars.count != transcript.count)
        let id = UUID()
        let result = try await TranscriptSummaryService(runner: runner).summarize(
            transcript: transcript, modelURL: fixture.model, requestID: id,
            expectedModelIdentity: fixture.digest, expectedPromptIdentity: SummaryReplyRunner.promptIdentity
        )
        #expect(result.summary == "A faithful local summary.")
        #expect(result.requestID == id)
        #expect(result.inputCharacters == transcript.unicodeScalars.count)
        #expect(result.transcriptDigest == summaryDigest(Data(transcript.utf8)))
        #expect(result.modelIdentity == fixture.digest)
        #expect(result.promptIdentity == SummaryReplyRunner.promptIdentity)
        #expect(result.modelURL == fixture.model.resolvingSymlinksInPath())
        let request = try #require(await runner.lastRequest())
        let object = try #require(try JSONSerialization.jsonObject(with: request) as? [String: Any])
        #expect(object["protocolVersion"] as? Int == 2)
        #expect(object["operation"] as? String == "summary")
        #expect(object["requestID"] as? String == id.uuidString.lowercased())
        #expect(object["transcriptText"] as? String == transcript)
        #expect(object["llmModel"] as? String == fixture.model.resolvingSymlinksInPath().path)
        #expect(object["audioPath"] == nil)
    }

    @Test(arguments: SummaryReplyFault.allCases)
    fileprivate func rejectsMalformedMismatchedOrIncompleteReplies(fault: SummaryReplyFault) async throws {
        let fixture = try SummaryModelFixture()
        defer { fixture.remove() }
        let service = TranscriptSummaryService(runner: SummaryReplyRunner(fault: fault))
        await #expect(throws: TranscriptSummaryError.self) {
            try await service.summarize(transcript: "Actual whole transcript 🌱", modelURL: fixture.model)
        }
    }

    @Test func knownModelAndPromptIdentitiesMustMatch() async throws {
        let fixture = try SummaryModelFixture()
        defer { fixture.remove() }
        let runner = SummaryReplyRunner()
        let service = TranscriptSummaryService(runner: runner)
        await #expect(throws: TranscriptSummaryError.identityMismatch) {
            try await service.summarize(transcript: "Whole text", modelURL: fixture.model,
                                        expectedModelIdentity: String(repeating: "a", count: 64))
        }
        await #expect(throws: TranscriptSummaryError.identityMismatch) {
            try await service.summarize(transcript: "Whole text", modelURL: fixture.model,
                                        expectedPromptIdentity: String(repeating: "c", count: 64))
        }
    }

    @Test func emptyTranscriptAndUnavailableModelNeverDispatch() async throws {
        let fixture = try SummaryModelFixture()
        defer { fixture.remove() }
        let runner = SummaryReplyRunner()
        let service = TranscriptSummaryService(runner: runner)
        await #expect(throws: TranscriptSummaryError.emptyTranscript) {
            try await service.summarize(transcript: " \n", modelURL: fixture.model)
        }
        for model in [URL(string: "https://example.test/model.gguf")!,
                      fixture.root.appendingPathComponent("missing.gguf"), fixture.root] {
            await #expect(throws: TranscriptSummaryError.modelUnavailable) {
                try await service.summarize(transcript: "Actual text", modelURL: model)
            }
        }
        #expect(await runner.lastRequest() == nil)
    }

    @Test func cancellationIgnoringRunnerCannotReturnAcceptedResult() async throws {
        let fixture = try SummaryModelFixture()
        defer { fixture.remove() }
        let runner = SuspendedSummaryRunner()
        let service = TranscriptSummaryService(runner: runner)
        let task = Task { try await service.summarize(transcript: "Actual text", modelURL: fixture.model) }
        await runner.waitUntilStarted()
        task.cancel()
        try await runner.release()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func alreadyCancelledCallerDoesNotDispatch() async throws {
        let fixture = try SummaryModelFixture()
        defer { fixture.remove() }
        let runner = SummaryReplyRunner()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await TranscriptSummaryService(runner: runner).summarize(
                transcript: "Actual text", modelURL: fixture.model
            )
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await runner.lastRequest() == nil)
    }

    @Test func samePathModelReplacementDuringWorkerWaitIsRejected() async throws {
        let fixture = try SummaryModelFixture()
        defer { fixture.remove() }
        let runner = SuspendedSummaryRunner()
        let task = Task { try await TranscriptSummaryService(runner: runner).summarize(
            transcript: "Actual text", modelURL: fixture.model
        ) }
        await runner.waitUntilStarted()
        try Data("different local model bytes".utf8).write(to: fixture.model)
        try await runner.release()
        await #expect(throws: TranscriptSummaryError.modelChanged) { try await task.value }
    }

    @Test func onlyMatchingSummaryProgressIsForwarded() async throws {
        let fixture = try SummaryModelFixture()
        defer { fixture.remove() }
        let id = UUID()
        let log = SummaryProgressLog()
        _ = try await TranscriptSummaryService(runner: SummaryReplyRunner()).summarize(
            transcript: "Actual text", modelURL: fixture.model, requestID: id,
            onProgress: { log.append($0) }
        )
        #expect(log.values.contains { $0.stage == "summary.generate" })
        #expect(log.values.allSatisfy { $0.requestID == id && $0.stage.hasPrefix("summary.") })
        #expect(!log.values.contains { $0.detail == "wrong or unbound" })
    }
}

private func summaryDigest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private struct SummaryModelFixture {
    let root: URL
    let model: URL
    let digest: String
    init() throws {
        root = OwnedTestTemp.root.appendingPathComponent("wilted-summary-service-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        model = root.appendingPathComponent("synthetic.gguf")
        let bytes = Data("synthetic model; no inference".utf8)
        try bytes.write(to: model)
        digest = summaryDigest(bytes)
        print("summary-service-fixture=\(root.path)")
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

private enum SummaryReplyFault: String, CaseIterable, Sendable {
    case invalidJSON, wrongVersion, wrongOperation, wrongID, uppercaseID, wrongDigest, wrongCount
    case partialCoverage, emptyRanges, gap, overlap, beyondEnd, malformedRange, emptySummary
    case invalidModelIdentity, wrongModelIdentity, invalidPromptIdentity, wrongModelPath
    case zeroTokens, excessiveTokens, insufficientTokens, negativeReduction, workerFailure
}

private actor SummaryReplyRunner: PodcastPipelineRunning {
    static let promptIdentity = String(repeating: "b", count: 64)
    let fault: SummaryReplyFault?
    private var request: Data?
    init(fault: SummaryReplyFault? = nil) { self.fault = fault }
    func lastRequest() -> Data? { request }
    func run(request: Data, onProgress: @escaping @Sendable (PodcastPreparationProgress) -> Void) async throws -> Data {
        self.request = request
        let object = try JSONSerialization.jsonObject(with: request) as! [String: Any]
        let id = UUID(uuidString: object["requestID"] as! String)!
        onProgress(PodcastPreparationProgress(stage: "summary.generate", requestID: id))
        onProgress(PodcastPreparationProgress(stage: "summary.generate", detail: "wrong or unbound", requestID: UUID()))
        onProgress(PodcastPreparationProgress(stage: "summary.generate", detail: "wrong or unbound"))
        onProgress(PodcastPreparationProgress(stage: "ads.model.wait", detail: "wrong or unbound", requestID: id))
        return try Self.reply(request, fault: fault)
    }
    static func reply(_ request: Data, fault: SummaryReplyFault? = nil) throws -> Data {
        let input = try JSONSerialization.jsonObject(with: request) as! [String: Any]
        let text = input["transcriptText"] as! String
        let count = text.unicodeScalars.count
        let modelPath = input["llmModel"] as! String
        var result: [String: Any] = [
            "ok": true, "protocolVersion": 2, "operation": "summary", "requestID": input["requestID"]!,
            "summary": "A faithful local summary.", "coverage": "whole", "inputCharacters": count,
            "coverageRanges": [[0, count]], "reductionLevels": 0, "completionTokens": 3,
            "transcriptDigest": summaryDigest(Data(text.utf8)), "promptIdentity": promptIdentity,
            "modelIdentity": summaryDigest(try Data(contentsOf: URL(fileURLWithPath: modelPath))), "modelPath": modelPath
        ]
        switch fault {
        case .invalidJSON: return Data("not JSON".utf8)
        case .wrongVersion: result["protocolVersion"] = 1
        case .wrongOperation: result["operation"] = "prepare"
        case .wrongID: result["requestID"] = UUID().uuidString.lowercased()
        case .uppercaseID: result["requestID"] = (input["requestID"] as! String).uppercased()
        case .wrongDigest: result["transcriptDigest"] = String(repeating: "a", count: 64)
        case .wrongCount: result["inputCharacters"] = count - 1
        case .partialCoverage: result["coverage"] = "partial"
        case .emptyRanges: result["coverageRanges"] = [[Int]]()
        case .gap: result["coverageRanges"] = [[1, count]]
        case .overlap: result["coverageRanges"] = [[0, count], [0, count]]
        case .beyondEnd: result["coverageRanges"] = [[0, count + 1]]
        case .malformedRange: result["coverageRanges"] = [[0, count, count]]
        case .emptySummary: result["summary"] = " \n"
        case .invalidModelIdentity: result["modelIdentity"] = "not a digest"
        case .wrongModelIdentity: result["modelIdentity"] = String(repeating: "a", count: 64)
        case .invalidPromptIdentity: result["promptIdentity"] = "not a digest"
        case .wrongModelPath: result["modelPath"] = modelPath + ".other"
        case .zeroTokens: result["completionTokens"] = 0
        case .excessiveTokens: result["completionTokens"] = 513
        case .insufficientTokens:
            result["coverageRanges"] = [[0, 1], [1, count]]
            result["reductionLevels"] = 1
            result["completionTokens"] = 2
        case .negativeReduction: result["reductionLevels"] = -1
        case .workerFailure: result["ok"] = false; result["code"] = "summary-generation-failed"; result["message"] = "No complete summary."
        case nil: break
        }
        return try JSONSerialization.data(withJSONObject: result)
    }
}

private actor SuspendedSummaryRunner: PodcastPipelineRunning {
    private var request: Data?
    private var result: CheckedContinuation<Data, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func run(request: Data, onProgress: @escaping @Sendable (PodcastPreparationProgress) -> Void) async throws -> Data {
        self.request = request
        started?.resume(); started = nil
        return await withCheckedContinuation { result = $0 }
    }
    func waitUntilStarted() async {
        if request != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func release() throws {
        let data = try SummaryReplyRunner.reply(request!)
        result?.resume(returning: data); result = nil
    }
}

private final class SummaryProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [PodcastPreparationProgress] = []
    func append(_ value: PodcastPreparationProgress) { lock.lock(); recorded.append(value); lock.unlock() }
    var values: [PodcastPreparationProgress] { lock.lock(); defer { lock.unlock() }; return recorded }
}
