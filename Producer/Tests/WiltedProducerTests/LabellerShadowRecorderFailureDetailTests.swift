import CryptoKit
import Foundation
import Testing
import WiltedDomain
@testable import WiltedProducer

@Suite("Labeller shadow recorder failure detail")
struct LabellerShadowRecorderFailureDetailTests {
    private static let feedURL = URL(string: "https://feeds.example.test/show.xml")!
    private static let feedID = try! ItemID.derivePodcastFeed(from: feedURL)
    private static let key = "invented-key-0123456789abcdef"
    private static let goodReply =
        #"{"breaks":[{"startSegment":1,"endSegment":2,"kind":"sponsor","label":"must-cut","advertisers":["Fizzbolt"]}]}"#

    /// Scripted sender: reports an optional failure detail, then throws or answers.
    private final class StubSender: LabellerSending, @unchecked Sendable {
        enum Outcome {
            case respond(String)
            case reject(LabellerFailureDetail, LabellerFailure)
        }

        private let outcome: Outcome
        init(_ outcome: Outcome) { self.outcome = outcome }

        func send(
            _ request: LabellerRequest,
            onRequestStarted: @escaping @Sendable () -> Void,
            onProgress: @escaping @Sendable (LabellerProgress) -> Void
        ) async throws -> LabellerResponse {
            onRequestStarted()
            switch outcome {
            case .respond(let text):
                return LabellerResponse(text: text, usage: LabellerUsage())
            case .reject(let detail, let failure):
                onProgress(LabellerProgress(bytesReceived: 10, answerCharacters: 0, failure: detail))
                throw failure
            }
        }
    }

    private struct Run {
        let records: URL
        let outcome: LabellerShadowRecorder.LabelOutcome
        let record: [String: Any]
        let attempt: [String: Any]
    }

    private func run(_ outcome: StubSender.Outcome) async throws -> Run {
        let name = "LabellerShadowRecorderFailureDetailTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let directory = OwnedTestTemp.root
            .appendingPathComponent("LabellerShadowRecorderFailureDetailTests-\(UUID().uuidString)", isDirectory: true)
        let records = directory.appendingPathComponent("records", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { defaults.removePersistentDomain(forName: name) }

        let cues = [
            LabellerCue(id: 0, start: 0, end: 3, text: "Welcome to the invented garden show."),
            LabellerCue(id: 1, start: 3, end: 7.5, text: "This break is brought to you by Fizzbolt."),
            LabellerCue(id: 2, start: 7.5, end: 10, text: "Fizzbolt makes invented widgets."),
            LabellerCue(id: 3, start: 10, end: 12, text: "Back to the show."),
        ]
        let data = try JSONEncoder().encode(cues)
        let cuePath = directory.appendingPathComponent("cues.json")
        try data.write(to: cuePath)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

        let preferences = AdLabellerPreferences(preferences: defaults)
        preferences.isEnabled = true
        preferences.isShadow = true
        preferences.setConfirmed(feedID: Self.feedID.rawValue, true)
        let recorder = LabellerShadowRecorder(
            preferences: preferences,
            counter: LabellerRequestCounter(preferences: defaults),
            keyStore: InMemoryLabellerKeyStore(key: Self.key),
            sender: StubSender(outcome),
            recordsDirectory: records,
            now: { Date(timeIntervalSince1970: 1_700_000_300) })
        let episodeID = "episode-detail"
        let result = await recorder.label(LabellerShadowRecorder.ShadowInput(
            episodeID: episodeID, feedID: Self.feedID.rawValue, feedURL: Self.feedURL,
            feedTitle: "Invented Garden Show", audioURL: URL(string: "https://cdn.example.test/e1.mp3"),
            durationSeconds: 12, cuesPath: cuePath.path, cuesDigest: digest,
            engineOutcome: "cut", engineCutSpans: []))

        let recordData = try Data(contentsOf: records.appendingPathComponent(
            LabellerShadowRecorder.recordFileName(for: episodeID)))
        let record = try #require(try JSONSerialization.jsonObject(with: recordData) as? [String: Any])
        let attempts = try String(contentsOf: records.appendingPathComponent(LabellerShadowRecorder.attemptsFileName),
                                  encoding: .utf8)
        let line = try #require(attempts.split(separator: "\n").last)
        let attempt = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        return Run(records: directory, outcome: result, record: record, attempt: attempt)
    }

    @Test func aRejectedKeyRecordsStatusAndProviderTypeInRecordAndAttempt() async throws {
        let run = try await run(.reject(LabellerFailureDetail(status: 403, errorType: "model_restricted"),
                                        .keyRejected))
        defer { try? FileManager.default.removeItem(at: run.records) }

        #expect(run.record["failureKind"] as? String == LabellerFailure.keyRejected.kind)
        #expect(run.record["httpStatus"] as? Int == 403)
        #expect(run.record["providerErrorType"] as? String == "model_restricted")
        #expect(run.attempt["httpStatus"] as? Int == 403)
        #expect(run.attempt["providerErrorType"] as? String == "model_restricted")
    }

    @Test func aRefusalWithoutATypeRecordsOnlyTheStatus() async throws {
        let run = try await run(.reject(LabellerFailureDetail(status: 401, errorType: nil), .keyRejected))
        defer { try? FileManager.default.removeItem(at: run.records) }

        #expect(run.record["httpStatus"] as? Int == 401)
        #expect(run.record["providerErrorType"] == nil)
        #expect(run.attempt["httpStatus"] as? Int == 401)
        #expect(run.attempt["providerErrorType"] == nil)
    }

    @Test func aSuccessWritesNeitherField() async throws {
        let run = try await run(.respond(Self.goodReply))
        defer { try? FileManager.default.removeItem(at: run.records) }

        #expect(run.record["httpStatus"] == nil)
        #expect(run.record["providerErrorType"] == nil)
        #expect(run.attempt["httpStatus"] == nil)
        #expect(run.attempt["providerErrorType"] == nil)
    }

    @Test func anUnusableAnswerWritesNeitherField() async throws {
        let run = try await run(.respond("I cannot answer in JSON."))
        defer { try? FileManager.default.removeItem(at: run.records) }

        #expect(run.record["failureKind"] as? String == LabellerFailure.unusableAnswer.kind)
        #expect(run.record["httpStatus"] == nil)
        #expect(run.record["providerErrorType"] == nil)
        #expect(run.attempt["httpStatus"] == nil)
        #expect(run.attempt["providerErrorType"] == nil)
    }
}
