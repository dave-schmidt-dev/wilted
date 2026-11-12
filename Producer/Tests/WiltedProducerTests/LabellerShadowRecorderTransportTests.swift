import CryptoKit
import Foundation
import Testing
import WiltedDomain
@testable import WiltedProducer

@Suite("Labeller shadow recorder transport")
struct LabellerShadowRecorderTransportTests {
    private static let feedURL = URL(string: "https://feeds.example.test/show.xml")!
    private static let feedID = try! ItemID.derivePodcastFeed(from: feedURL)
    private static let goodReply =
        #"{"breaks":[{"startSegment":1,"endSegment":2,"kind":"sponsor","label":"must-cut","advertisers":["Fizzbolt"]}]}"#

    private struct StubSender: LabellerSending {
        let reply: String?

        func send(
            _ request: LabellerRequest,
            onRequestStarted: @escaping @Sendable () -> Void,
            onProgress: @escaping @Sendable (LabellerProgress) -> Void
        ) async throws -> LabellerResponse {
            onRequestStarted()
            guard let reply else { throw LabellerFailure.temporary }
            return LabellerResponse(text: reply, usage: LabellerUsage())
        }
    }

    private struct Run {
        let directory: URL
        let record: [String: Any]
        let attempt: [String: Any]
    }

    /// Runs one episode; `transport` nil uses the initialiser default, `confirmed` false keeps it local.
    private func run(reply: String?, transport: String?, confirmed: Bool = true) async throws -> Run {
        let name = "LabellerShadowRecorderTransportTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let directory = OwnedTestTemp.root
            .appendingPathComponent("LabellerShadowRecorderTransportTests-\(UUID().uuidString)", isDirectory: true)
        let records = directory.appendingPathComponent("records", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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
        preferences.setConfirmed(feedID: Self.feedID.rawValue, confirmed)
        let counter = LabellerRequestCounter(preferences: defaults)
        let keyStore = InMemoryLabellerKeyStore(key: "invented-key-0123456789abcdef")
        let sender = StubSender(reply: reply)
        let clock: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_700_000_300) }
        let recorder = transport.map {
            LabellerShadowRecorder(preferences: preferences, counter: counter, keyStore: keyStore, sender: sender,
                                   transport: $0, recordsDirectory: records, now: clock)
        } ?? LabellerShadowRecorder(preferences: preferences, counter: counter, keyStore: keyStore,
                                    sender: sender, recordsDirectory: records, now: clock)
        let episodeID = "episode-transport"
        _ = await recorder.label(LabellerShadowRecorder.ShadowInput(
            episodeID: episodeID, feedID: Self.feedID.rawValue, feedURL: Self.feedURL,
            feedTitle: "Invented Garden Show", audioURL: URL(string: "https://cdn.example.test/e1.mp3"),
            durationSeconds: 12, cuesPath: cuePath.path, cuesDigest: digest,
            engineOutcome: "cut", engineCutSpans: []))
        // `label` writes nothing for a local route; `schedule` records it.
        if !confirmed {
            await recorder.schedule(LabellerShadowRecorder.ShadowInput(
                episodeID: episodeID, feedID: Self.feedID.rawValue, feedURL: Self.feedURL,
                feedTitle: "Invented Garden Show", audioURL: URL(string: "https://cdn.example.test/e1.mp3"),
                durationSeconds: 12, cuesPath: cuePath.path, cuesDigest: digest,
                engineOutcome: "cut", engineCutSpans: []))
        }
        let recordData = try Data(contentsOf: records.appendingPathComponent(
            LabellerShadowRecorder.recordFileName(for: episodeID)))
        let record = try #require(try JSONSerialization.jsonObject(with: recordData) as? [String: Any])
        let attempts = try String(contentsOf: records.appendingPathComponent(LabellerShadowRecorder.attemptsFileName),
                                  encoding: .utf8)
        let line = try #require(attempts.split(separator: "\n").last)
        let attempt = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        return Run(directory: directory, record: record, attempt: attempt)
    }

    @Test(arguments: [(nil as String?, "direct"), ("opencode-cli", "opencode-cli")])
    func aLabelledRecordAndItsAttemptCarryTheTransport(given: String?, expected: String) async throws {
        let run = try await run(reply: Self.goodReply, transport: given)
        defer { try? FileManager.default.removeItem(at: run.directory) }
        #expect(run.record["failureKind"] == nil)
        #expect(run.record["transport"] as? String == expected)
        #expect(run.attempt["outcome"] as? String == "recorded")
        #expect(run.attempt["transport"] as? String == expected)
    }

    @Test(arguments: [(nil as String?, "direct"), ("opencode-cli", "opencode-cli")])
    func aFailedRecordAndItsAttemptCarryTheTransport(given: String?, expected: String) async throws {
        let run = try await run(reply: nil, transport: given)
        defer { try? FileManager.default.removeItem(at: run.directory) }
        #expect(run.record["failureKind"] as? String == LabellerFailure.temporary.kind)
        #expect(run.record["transport"] as? String == expected)
        #expect(run.attempt["transport"] as? String == expected)
    }

    @Test func aNotRoutedEpisodeWritesNoTransport() async throws {
        let run = try await run(reply: Self.goodReply, transport: "opencode-cli", confirmed: false)
        defer { try? FileManager.default.removeItem(at: run.directory) }
        #expect(run.record["route"] as? String == "local")
        #expect(run.record["transport"] == nil)
        #expect(run.attempt["outcome"] as? String == "local")
        #expect(run.attempt["transport"] == nil)
    }
}
