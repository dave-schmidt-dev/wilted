import CryptoKit
import Foundation
import SwiftData
import Testing
import WiltedDomain
@testable import WiltedProducer

/// The label-only backfill: one worker call exports cue files from stored
/// transcripts, then each pending episode is labelled in shadow mode. The
/// library must come out exactly as it went in, and only shadow records may
/// appear.
@Suite("Labeller backfill")
struct LabellerBackfillTests {
    private static let feedURL = URL(string: "https://feeds.example.test/show.xml")!
    private static let feedID = try! ItemID.derivePodcastFeed(from: feedURL)
    private static let showTitle = "Invented Garden Show"
    private static let key = "invented-key-0123456789abcdef"
    private static let engineVersion = "engine-v9"
    private static let goodReply =
        #"{"breaks":[{"startSegment":1,"endSegment":2,"kind":"sponsor","label":"must-cut","advertisers":["Fizzbolt"]}]}"#
    private static let garbageReply = "I cannot answer in JSON."

    /// One episode the fixture journalled a finished attempt for.
    private struct PreparedEpisode {
        let episode: PodcastEpisode
        let sourceHash: String
        let cues: [LabellerCue]
    }

    // MARK: Doubles

    /// Stands in for the labelling client: scripted outcomes, one per call.
    private final class StubSender: LabellerSending, @unchecked Sendable {
        enum Outcome {
            case respond(LabellerResponse)
            case fail(any Error)
            case hang
        }

        private let lock = NSLock()
        private var outcomes: [Outcome]
        private var sent = 0

        init(outcomes: [Outcome]) { self.outcomes = outcomes }

        var requestCount: Int { lock.withLock { sent } }

        func send(
            _ request: LabellerRequest,
            onRequestStarted: @escaping @Sendable () -> Void,
            onProgress: @escaping @Sendable (LabellerProgress) -> Void
        ) async throws -> LabellerResponse {
            let index = lock.withLock {
                sent += 1
                return sent - 1
            }
            onRequestStarted()
            let outcome = lock.withLock {
                outcomes.indices.contains(index) ? outcomes[index] : outcomes.last ?? .fail(LabellerFailure.temporary)
            }
            switch outcome {
            case .respond(let response):
                return response
            case .fail(let error):
                throw error
            case .hang:
                while true { try await Task.sleep(for: .milliseconds(5)) }
            }
        }
    }

    /// Stands in for the Python worker: writes cue files into the export
    /// directory and answers with the cue-export contract JSON.
    private final class CuesExportWorker: PodcastPipelineRunning, @unchecked Sendable {
        enum Script {
            /// Exports every episode's cues.
            case export
            /// Creates the export directory, then reports failure.
            case reportFailure
            /// Creates the export directory, then throws.
            case throwFailure
            /// Answers with bytes that are not the contract reply.
            case malformed
            /// Waits to be cancelled, then throws the cancellation.
            case hangUntilCancelled
        }

        private let lock = NSLock()
        private let script: Script
        private let exports: [PreparedEpisode]
        private var calls = 0
        private var lastRequest: Data?

        init(script: Script, exports: [PreparedEpisode]) {
            self.script = script
            self.exports = exports
        }

        var callCount: Int { lock.withLock { calls } }
        var request: Data? { lock.withLock { lastRequest } }

        func run(
            request payload: Data,
            onProgress: @escaping @Sendable (PodcastPreparationProgress) -> Void
        ) async throws -> Data {
            lock.withLock {
                calls += 1
                lastRequest = payload
            }
            let decoded = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] ?? [:]
            let exportDirectory = URL(fileURLWithPath: decoded["workDir"] as? String ?? "")
                .appendingPathComponent("wilted-pipeline", isDirectory: true)
                .appendingPathComponent("labeller-backfill", isDirectory: true)
            try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
            switch script {
            case .export:
                break
            case .reportFailure:
                return try JSONSerialization.data(withJSONObject: [
                    "ok": false, "operation": "labellerCues", "protocolVersion": 2,
                    "code": "noTranscripts", "message": "no stored transcripts"])
            case .throwFailure:
                throw PodcastPreparationError.workerUnavailable("offline")
            case .malformed:
                return Data("not the contract reply".utf8)
            case .hangUntilCancelled:
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(2)) }
                throw CancellationError()
            }
            var exported: [[String: Any]] = []
            for episode in exports {
                let data = try JSONEncoder().encode(episode.cues)
                let url = exportDirectory.appendingPathComponent("cues-\(episode.sourceHash.suffix(8)).json")
                try data.write(to: url)
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                exported.append([
                    "sourceHash": episode.sourceHash,
                    "cuesPath": url.path,
                    "cuesDigest": digest,
                    "cueCount": episode.cues.count,
                    "lastCueEnd": episode.cues.last?.end ?? 0,
                ])
            }
            return try JSONSerialization.data(withJSONObject: [
                "ok": true, "operation": "labellerCues", "protocolVersion": 2,
                "exportDirectory": exportDirectory.path,
                "exports": exported, "skipped": 0])
        }
    }

    /// Collects progress callbacks from a `@Sendable` closure.
    private final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [LabellerBackfill.Progress] = []

        func append(_ value: LabellerBackfill.Progress) { lock.withLock { values.append(value) } }
        var all: [LabellerBackfill.Progress] { lock.withLock { values } }
    }

    // MARK: Fixture

    private struct Fixture {
        let root: URL
        let store: LocalLibraryStore
        let workDirectory: URL
        let defaults: UserDefaults
        let defaultsName: String

        static func make() async throws -> Fixture {
            let root = OwnedTestTemp.root
                .appendingPathComponent("LabellerBackfillTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let workDirectory = root.appendingPathComponent("Work", isDirectory: true)
            try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
            let store = try LocalLibraryStore(url: root.appendingPathComponent("library.sqlite"))
            try await store.save(feed: PodcastFeed(
                itemID: LabellerBackfillTests.feedID,
                canonicalURL: LabellerBackfillTests.feedURL,
                title: LabellerBackfillTests.showTitle,
                createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
            ))
            let name = "LabellerBackfillTests.\(UUID().uuidString)"
            return Fixture(root: root, store: store, workDirectory: workDirectory,
                          defaults: UserDefaults(suiteName: name)!, defaultsName: name)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: defaultsName)
        }
    }

    /// Adds an episode with a finished journalled attempt over `sourceHash`,
    /// plus the ready revision and outcome the backfill must leave alone.
    /// Calling it again with the same ordinal and a higher `sequence` adds a
    /// newer attempt to the same episode.
    @discardableResult
    private func addEpisode(
        _ fixture: Fixture, ordinal: Int, sequence: Int = 1, outcome: String = "cut",
        workerResult: Bool = true, removed: (start: Double, end: Double) = (3, 7.5)
    ) async throws -> PreparedEpisode {
        let enclosureURL = try #require(URL(string: "https://cdn.example.test/e\(ordinal).mp3"))
        let episodeID = try ItemID.derivePodcastEpisode(
            feedURL: Self.feedURL, rssGUID: "e\(ordinal)", enclosureURL: enclosureURL)
        let episode = try PodcastEpisode(
            itemID: episodeID, feedID: Self.feedID, feedURL: Self.feedURL, rssGUID: "e\(ordinal)",
            title: "Episode \(ordinal)", enclosureURL: enclosureURL, enclosureMediaType: "audio/mpeg",
            durationSeconds: 120, createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000)))
        try await fixture.store.save(episode: episode)

        let sourceHash = "sha256:" + String(repeating: "a", count: 60) + String(format: "%04d", ordinal)
        let revisionID = try RevisionID(rawValue: "backfill-revision-\(ordinal)")
        let base = Date(timeIntervalSince1970: 1_700_000_100)
        let attempt = try PreparationAttemptIdentity(requestSequence: sequence, attemptCount: 1)
        let requestID = PodcastPreparationPipeline.requestID(for: episodeID)
        let prefix = requestID + "|" + attempt.key + "|"
        let context = ModelContext(fixture.store.container)
        let provenance = try PreparationEvidence(
            kind: LocalLibraryStore.pipelineProvenanceEvidenceKind,
            fields: ["sourceRevisionID": revisionID.rawValue, "sourceHash": sourceHash,
                     "engineVersion": Self.engineVersion])
        try insertJournal(context, id: prefix + "pipeline.start#1", episodeID: episodeID,
                          requestID: requestID, stage: .preparing, at: base, attempt: attempt,
                          evidence: provenance)
        if workerResult {
            let result = try PreparationEvidence(kind: "worker-result", fields: [
                "adRemovalOutcome": outcome, "audioChanged": "true"])
            try insertJournal(context, id: prefix + "pipeline.result#2", episodeID: episodeID,
                              requestID: requestID, stage: .assembling, at: base.addingTimeInterval(1),
                              attempt: attempt, evidence: result)
        }
        let timeline = try PreparationStatus.PreparationTimeline(
            removed: [.init(originalStartSeconds: removed.start, originalEndSeconds: removed.end,
                            label: "host read", confidence: 0.9)],
            kept: [.init(originalStartSeconds: 0, originalEndSeconds: removed.start, outputStartSeconds: 0),
                   .init(originalStartSeconds: removed.end, originalEndSeconds: 12,
                         outputStartSeconds: removed.start)])
        try insertJournal(context, id: prefix + "terminal", episodeID: episodeID, requestID: requestID,
                          stage: .completed, at: base.addingTimeInterval(2), attempt: attempt,
                          terminal: try PreparationTerminalResult(outcome: .succeeded, revisionID: revisionID),
                          timeline: timeline)
        try context.save()

        let revisionHash = "sha256:" + String(repeating: "b", count: 60) + String(format: "%04d", ordinal)
        let revision = try AudioRevision(
            itemID: episodeID, revisionID: revisionID, durationSeconds: 7.5, byteCount: 100,
            contentHash: revisionHash, mediaType: "audio/mpeg", createdAt: Timestamp(base), schemaVersion: 3)
        try await fixture.store.saveReadyRevision(
            revision,
            mediaURL: fixture.root.appendingPathComponent("media-\(ordinal).mp3"),
            transcript: Transcript(itemID: episodeID, revisionID: revisionID, availability: .available,
                                   text: "Words.", updatedAt: Timestamp(base)),
            outcome: PodcastPreparationOutcome(
                episodeID: episodeID, revisionID: revisionID, policyDigest: "policy",
                pipelineFingerprint: "fingerprint", semanticVersion: Self.engineVersion,
                producedAt: Timestamp(base)))
        return PreparedEpisode(episode: episode, sourceHash: sourceHash, cues: [
            LabellerCue(id: 0, start: 0, end: 3, text: "Welcome to the invented garden show."),
            LabellerCue(id: 1, start: 3, end: 7.5, text: "This break is brought to you by Fizzbolt."),
            LabellerCue(id: 2, start: 7.5, end: 10, text: "Fizzbolt makes invented widgets."),
            LabellerCue(id: 3, start: 10, end: 12, text: "Back to the show."),
        ])
    }

    private func insertJournal(
        _ context: ModelContext, id: String, episodeID: ItemID, requestID: String,
        stage: PreparationStage, at date: Date, attempt: PreparationAttemptIdentity,
        evidence: PreparationEvidence? = nil, terminal: PreparationTerminalResult? = nil,
        timeline: PreparationStatus.PreparationTimeline? = nil
    ) throws {
        let status = try PreparationStatus(
            stage: stage, detail: "backfill \(id)", cancellable: terminal == nil,
            terminalResult: terminal, emittedAt: Timestamp(date), evidence: evidence,
            timeline: timeline, attempt: attempt)
        context.insert(try LocalLibrarySchemaV3Models.PreparationRecord(PreparationJournalEntry(
            id: id, itemID: episodeID, requestID: requestID, status: status)))
    }

    private func makeRecorder(
        fixture: Fixture, sender: any LabellerSending, recordsDirectory: URL,
        confirmed: Bool = true, dailyCap: Int? = nil, enabled: Bool = true
    ) -> LabellerShadowRecorder {
        let preferences = AdLabellerPreferences(preferences: fixture.defaults)
        preferences.isEnabled = enabled
        preferences.isShadow = true
        if let dailyCap { preferences.dailyCap = dailyCap }
        if confirmed { preferences.setConfirmed(feedID: Self.feedID.rawValue, true) }
        return LabellerShadowRecorder(
            preferences: preferences,
            counter: LabellerRequestCounter(preferences: fixture.defaults),
            keyStore: InMemoryLabellerKeyStore(key: Self.key),
            sender: sender,
            recordsDirectory: recordsDirectory,
            now: { Date(timeIntervalSince1970: 1_700_000_300) }
        )
    }

    private func makeBackfill(
        fixture: Fixture, recorder: LabellerShadowRecorder, worker: CuesExportWorker
    ) -> LabellerBackfill {
        LabellerBackfill(store: fixture.store, recorder: recorder, runner: worker,
                         workDirectory: fixture.workDirectory)
    }

    private func recordsDirectory(_ name: String) throws -> URL {
        let url = OwnedTestTemp.root
            .appendingPathComponent("LabellerBackfillTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func exportDirectory(_ fixture: Fixture) -> URL {
        fixture.workDirectory.appendingPathComponent("wilted-pipeline", isDirectory: true)
            .appendingPathComponent("labeller-backfill", isDirectory: true)
    }

    private func recordURL(_ directory: URL, episodeID: ItemID) -> URL {
        directory.appendingPathComponent(LabellerShadowRecorder.recordFileName(for: episodeID.rawValue))
    }

    private func readRecord(_ directory: URL, episodeID: ItemID) throws -> [String: Any] {
        let data = try Data(contentsOf: recordURL(directory, episodeID: episodeID))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Writes a record file as an earlier run would have left it.
    private func writeRecord(_ directory: URL, episodeID: ItemID, route: String,
                             failureKind: String?) throws {
        var fields: [String: Any] = [
            "schemaVersion": 1, "recordedAt": "2023-11-14T12:30:00Z",
            "episodeID": episodeID.rawValue, "feedID": Self.feedID.rawValue,
            "route": route, "engineOutcome": "cut", "engineCutSpans": [[String: Any]](),
        ]
        if let failureKind { fields["failureKind"] = failureKind }
        let data = try JSONSerialization.data(withJSONObject: fields, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: recordURL(directory, episodeID: episodeID))
    }

    private func rowCount<T: PersistentModel>(_: T.Type, in store: LocalLibraryStore) throws -> Int {
        try ModelContext(store.container).fetchCount(FetchDescriptor<T>())
    }

    /// The episodes in the order the backfill labels them: episode-ID order.
    private func labelledFirst(_ episodes: [PreparedEpisode]) -> [PreparedEpisode] {
        episodes.sorted { $0.episode.itemID.rawValue < $1.episode.itemID.rawValue }
    }

    // MARK: The batch

    @Test func aFinishedRunRecordsOneBackfillRecordPerEpisodeAndLeavesTheLibraryUnchanged() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let episodes = labelledFirst([
            try await addEpisode(fixture, ordinal: 1),
            try await addEpisode(fixture, ordinal: 2),
        ])
        let records = try recordsDirectory("finished")
        defer { try? FileManager.default.removeItem(at: records) }
        let sender = StubSender(outcomes: [
            .respond(LabellerResponse(text: Self.goodReply, usage: LabellerUsage())),
            .respond(LabellerResponse(text: Self.goodReply, usage: LabellerUsage())),
        ])
        let recorder = makeRecorder(fixture: fixture, sender: sender, recordsDirectory: records)
        let worker = CuesExportWorker(script: .export, exports: episodes)
        let backfill = makeBackfill(fixture: fixture, recorder: recorder, worker: worker)

        let journalBefore = try rowCount(LocalLibrarySchemaV3Models.PreparationRecord.self, in: fixture.store)
        let revisionsBefore = try rowCount(LocalLibrarySchemaV3Models.RevisionRecord.self, in: fixture.store)
        let outcomesBefore = try rowCount(
            LocalLibrarySchemaV10Models.PodcastPreparationOutcomeRecord.self, in: fixture.store)
        #expect(journalBefore == 6, "three journal entries per episode")
        #expect(revisionsBefore == 2)
        #expect(outcomesBefore == 2)

        let summary = await backfill.run()

        #expect(summary == LabellerBackfill.Summary(recorded: 2, failed: 0, remaining: 0, ending: .finished))
        #expect(sender.requestCount == 2)
        #expect(worker.callCount == 1, "one export call for the whole batch")
        let requestData = try #require(worker.request)
        let request = try #require(try JSONSerialization.jsonObject(with: requestData) as? [String: Any])
        #expect(request["operation"] as? String == "labellerCues")
        #expect(request["protocolVersion"] as? Int == 2)
        #expect(request["workDir"] as? String == fixture.workDirectory.path)

        #expect(try rowCount(LocalLibrarySchemaV3Models.PreparationRecord.self, in: fixture.store) == journalBefore)
        #expect(try rowCount(LocalLibrarySchemaV3Models.RevisionRecord.self, in: fixture.store) == revisionsBefore)
        #expect(try rowCount(LocalLibrarySchemaV10Models.PodcastPreparationOutcomeRecord.self, in: fixture.store)
            == outcomesBefore)

        for episode in episodes {
            let record = try readRecord(records, episodeID: episode.episode.itemID)
            #expect(record["route"] as? String == "remote")
            #expect(record["source"] as? String == "backfill")
            #expect(record["engineOutcome"] as? String == "cut")
            #expect(record["engineVersion"] as? String == Self.engineVersion)
            #expect(record["failureKind"] == nil)
            #expect((record["proposedBreaks"] as? [[String: Any]])?.count == 1)
            let spans = try #require(record["engineCutSpans"] as? [[String: Any]])
            #expect(spans.count == 1)
            #expect(spans.first?["start"] as? Double == 3.0)
            #expect(spans.first?["end"] as? Double == 7.5)
        }
        #expect(!FileManager.default.fileExists(atPath: exportDirectory(fixture).path),
               "the export directory is removed")
    }

    @Test func anEpisodeWithALabelledRecordIsSkippedAndOneWithAFailedRecordIsSentAgain() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let episodes = labelledFirst([
            try await addEpisode(fixture, ordinal: 1),
            try await addEpisode(fixture, ordinal: 2),
        ])
        let records = try recordsDirectory("labelled")
        defer { try? FileManager.default.removeItem(at: records) }
        // The first episode already has a comparison; the second only a failure.
        try writeRecord(records, episodeID: episodes[0].episode.itemID, route: "remote", failureKind: nil)
        try writeRecord(records, episodeID: episodes[1].episode.itemID, route: "remote", failureKind: "rate-limited")

        let sender = StubSender(outcomes: [.respond(LabellerResponse(text: Self.goodReply, usage: LabellerUsage()))])
        let recorder = makeRecorder(fixture: fixture, sender: sender, recordsDirectory: records)
        let backfill = makeBackfill(fixture: fixture, recorder: recorder,
                                    worker: CuesExportWorker(script: .export, exports: episodes))

        let summary = await backfill.run()

        #expect(summary == LabellerBackfill.Summary(recorded: 1, failed: 0, remaining: 0, ending: .finished))
        #expect(sender.requestCount == 1, "only the failed record's episode is sent")
        // The labelled episode's record is untouched; the failed one is replaced.
        #expect(try readRecord(records, episodeID: episodes[0].episode.itemID)["proposedBreaks"] == nil)
        #expect(try readRecord(records, episodeID: episodes[1].episode.itemID)["failureKind"] == nil)
        #expect(!FileManager.default.fileExists(atPath: exportDirectory(fixture).path))
    }

    @Test func anEpisodeOnAnUnconfirmedShowIsNotSentAndGetsNoRecord() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let episodes = [try await addEpisode(fixture, ordinal: 1)]
        let records = try recordsDirectory("unconfirmed")
        defer { try? FileManager.default.removeItem(at: records) }
        let sender = StubSender(outcomes: [.respond(LabellerResponse(text: Self.goodReply, usage: LabellerUsage()))])
        let recorder = makeRecorder(fixture: fixture, sender: sender, recordsDirectory: records, confirmed: false)
        let backfill = makeBackfill(fixture: fixture, recorder: recorder,
                                    worker: CuesExportWorker(script: .export, exports: episodes))

        let summary = await backfill.run()

        #expect(summary == LabellerBackfill.Summary(recorded: 0, failed: 0, remaining: 0, ending: .nothingToLabel))
        #expect(sender.requestCount == 0)
        #expect(!FileManager.default.fileExists(atPath: recordURL(records, episodeID: episodes[0].episode.itemID).path),
               "the policy keeps the episode local without writing a record")
        #expect(!FileManager.default.fileExists(atPath: exportDirectory(fixture).path))
    }

    @Test func anUnusableAnswerCountsFailedAndContinues() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let episodes = labelledFirst([
            try await addEpisode(fixture, ordinal: 1),
            try await addEpisode(fixture, ordinal: 2),
        ])
        let records = try recordsDirectory("unusable")
        defer { try? FileManager.default.removeItem(at: records) }
        let sender = StubSender(outcomes: [
            .respond(LabellerResponse(text: Self.garbageReply, usage: LabellerUsage())),
            .respond(LabellerResponse(text: Self.garbageReply, usage: LabellerUsage())),
            .respond(LabellerResponse(text: Self.goodReply, usage: LabellerUsage())),
        ])
        let recorder = makeRecorder(fixture: fixture, sender: sender, recordsDirectory: records)
        let backfill = makeBackfill(fixture: fixture, recorder: recorder,
                                    worker: CuesExportWorker(script: .export, exports: episodes))

        let summary = await backfill.run()

        #expect(summary == LabellerBackfill.Summary(recorded: 1, failed: 1, remaining: 0, ending: .finished))
        #expect(sender.requestCount == 3, "the unusable answer was retried once, then the next episode was labelled")
        #expect(try readRecord(records, episodeID: episodes[0].episode.itemID)["failureKind"] as? String
            == "unusable-answer")
        #expect(try readRecord(records, episodeID: episodes[1].episode.itemID)["failureKind"] == nil)
        #expect(!FileManager.default.fileExists(atPath: exportDirectory(fixture).path))
    }

    @Test func aRateLimitedReplyStopsTheBatch() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let episodes = labelledFirst([
            try await addEpisode(fixture, ordinal: 1),
            try await addEpisode(fixture, ordinal: 2),
        ])
        let records = try recordsDirectory("rate")
        defer { try? FileManager.default.removeItem(at: records) }
        let sender = StubSender(outcomes: [.fail(LabellerFailure.rateLimited(retryAfter: nil))])
        let recorder = makeRecorder(fixture: fixture, sender: sender, recordsDirectory: records)
        let backfill = makeBackfill(fixture: fixture, recorder: recorder,
                                    worker: CuesExportWorker(script: .export, exports: episodes))

        let summary = await backfill.run()

        #expect(summary == LabellerBackfill.Summary(recorded: 0, failed: 1, remaining: 1,
                                                    ending: .stopped(kind: "rate-limited")))
        #expect(sender.requestCount == 1, "the second episode is never sent")
        #expect(try readRecord(records, episodeID: episodes[0].episode.itemID)["failureKind"] as? String
            == "rate-limited")
        #expect(!FileManager.default.fileExists(atPath: recordURL(records, episodeID: episodes[1].episode.itemID).path))
        #expect(!FileManager.default.fileExists(atPath: exportDirectory(fixture).path))
    }

    @Test func aKeyRejectedReplyStopsTheBatch() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let episodes = labelledFirst([
            try await addEpisode(fixture, ordinal: 1),
            try await addEpisode(fixture, ordinal: 2),
        ])
        let records = try recordsDirectory("key")
        defer { try? FileManager.default.removeItem(at: records) }
        let sender = StubSender(outcomes: [.fail(LabellerFailure.keyRejected)])
        let recorder = makeRecorder(fixture: fixture, sender: sender, recordsDirectory: records)
        let backfill = makeBackfill(fixture: fixture, recorder: recorder,
                                    worker: CuesExportWorker(script: .export, exports: episodes))

        let summary = await backfill.run()

        #expect(summary == LabellerBackfill.Summary(recorded: 0, failed: 1, remaining: 1,
                                                    ending: .stopped(kind: "key-rejected")))
        #expect(sender.requestCount == 1)
        #expect(!FileManager.default.fileExists(atPath: exportDirectory(fixture).path))
    }

    @Test func theDailyCapStopsTheBatchAndNoRequestIsSentPastIt() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let episodes = labelledFirst([
            try await addEpisode(fixture, ordinal: 1),
            try await addEpisode(fixture, ordinal: 2),
        ])
        let records = try recordsDirectory("cap")
        defer { try? FileManager.default.removeItem(at: records) }
        let sender = StubSender(outcomes: [.respond(LabellerResponse(text: Self.goodReply, usage: LabellerUsage()))])
        let recorder = makeRecorder(fixture: fixture, sender: sender, recordsDirectory: records, dailyCap: 1)
        let backfill = makeBackfill(fixture: fixture, recorder: recorder,
                                    worker: CuesExportWorker(script: .export, exports: episodes))

        let summary = await backfill.run()

        #expect(summary == LabellerBackfill.Summary(recorded: 1, failed: 0, remaining: 1, ending: .dailyCapReached))
        #expect(sender.requestCount == 1, "no request is sent past the cap")
        #expect(try readRecord(records, episodeID: episodes[0].episode.itemID)["failureKind"] == nil)
        #expect(!FileManager.default.fileExists(atPath: recordURL(records, episodeID: episodes[1].episode.itemID).path))
        #expect(!FileManager.default.fileExists(atPath: exportDirectory(fixture).path))

        // A cap already spent stops the batch before the worker is called.
        let spent = try await Fixture.make()
        defer { spent.remove() }
        let spentSender = StubSender(outcomes: [])
        let spentRecorder = makeRecorder(fixture: spent, sender: spentSender,
                                         recordsDirectory: try recordsDirectory("cap-spent"), dailyCap: 0)
        let spentWorker = CuesExportWorker(script: .export, exports: [])
        let spentSummary = await makeBackfill(fixture: spent, recorder: spentRecorder, worker: spentWorker).run()
        #expect(spentSummary == LabellerBackfill.Summary(recorded: 0, failed: 0, remaining: 0,
                                                         ending: .dailyCapReached))
        #expect(spentWorker.callCount == 0)
    }

    @Test func withTheSwitchOffTheBackfillIsInactiveWithoutCallingTheWorker() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let episodes = [try await addEpisode(fixture, ordinal: 1)]
        let records = try recordsDirectory("off")
        defer { try? FileManager.default.removeItem(at: records) }
        let sender = StubSender(outcomes: [.respond(LabellerResponse(text: Self.goodReply, usage: LabellerUsage()))])
        let recorder = makeRecorder(fixture: fixture, sender: sender, recordsDirectory: records, enabled: false)
        let worker = CuesExportWorker(script: .export, exports: episodes)
        let backfill = makeBackfill(fixture: fixture, recorder: recorder, worker: worker)

        let summary = await backfill.run()

        #expect(summary == LabellerBackfill.Summary(recorded: 0, failed: 0, remaining: 0, ending: .inactive))
        #expect(worker.callCount == 0)
        #expect(sender.requestCount == 0)
        #expect(!FileManager.default.fileExists(atPath: exportDirectory(fixture).path))
    }

    @Test func aWorkerFailureEndsUnavailable() async throws {
        for script in [CuesExportWorker.Script.reportFailure, .throwFailure, .malformed] {
            let fixture = try await Fixture.make()
            defer { fixture.remove() }
            let episodes = [try await addEpisode(fixture, ordinal: 1)]
            let records = try recordsDirectory("worker")
            defer { try? FileManager.default.removeItem(at: records) }
            let sender = StubSender(outcomes: [.respond(LabellerResponse(text: Self.goodReply, usage: LabellerUsage()))])
            let recorder = makeRecorder(fixture: fixture, sender: sender, recordsDirectory: records)
            let backfill = makeBackfill(fixture: fixture, recorder: recorder,
                                        worker: CuesExportWorker(script: script, exports: episodes))

            let summary = await backfill.run()

            #expect(summary == LabellerBackfill.Summary(recorded: 0, failed: 0, remaining: 0, ending: .unavailable))
            #expect(sender.requestCount == 0)
            #expect(!FileManager.default.fileExists(atPath: exportDirectory(fixture).path),
                   "the export directory is removed even when the worker failed")
        }
    }

    @Test func aStopDuringTheExportEndsCancelledNotUnavailable() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let records = try recordsDirectory("cancel-export")
        defer { try? FileManager.default.removeItem(at: records) }
        let sender = StubSender(outcomes: [])
        let recorder = makeRecorder(fixture: fixture, sender: sender, recordsDirectory: records)
        let worker = CuesExportWorker(script: .hangUntilCancelled, exports: [])
        let backfill = makeBackfill(fixture: fixture, recorder: recorder, worker: worker)

        let task = Task { await backfill.run() }
        var polls = 0
        while worker.callCount == 0, polls < 5_000 {
            try await Task.sleep(for: .milliseconds(2))
            polls += 1
        }
        task.cancel()

        #expect(await task.value == LabellerBackfill.Summary(recorded: 0, failed: 0, remaining: 0, ending: .cancelled))
        #expect(sender.requestCount == 0)
        #expect(!FileManager.default.fileExists(atPath: exportDirectory(fixture).path))
    }

    @Test func cancellationMidBatchReturnsCancelledAndWritesNoRecordForTheCancelledEpisode() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let episodes = labelledFirst([
            try await addEpisode(fixture, ordinal: 1),
            try await addEpisode(fixture, ordinal: 2),
        ])
        let records = try recordsDirectory("cancel")
        defer { try? FileManager.default.removeItem(at: records) }
        let sender = StubSender(outcomes: [.hang])
        let recorder = makeRecorder(fixture: fixture, sender: sender, recordsDirectory: records)
        let backfill = makeBackfill(fixture: fixture, recorder: recorder,
                                    worker: CuesExportWorker(script: .export, exports: episodes))

        let task = Task { await backfill.run() }
        var polls = 0
        while sender.requestCount == 0, polls < 5_000 {
            try await Task.sleep(for: .milliseconds(2))
            polls += 1
        }
        task.cancel()
        let summary = await task.value

        #expect(summary == LabellerBackfill.Summary(recorded: 0, failed: 0, remaining: 1, ending: .cancelled))
        for episode in episodes {
            #expect(!FileManager.default.fileExists(atPath: recordURL(records, episodeID: episode.episode.itemID).path),
                   "a cancelled episode writes no record")
        }
        #expect(!FileManager.default.fileExists(atPath: exportDirectory(fixture).path))
    }

    @Test func progressIsReportedWithDoneAndTotal() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let episodes = labelledFirst([
            try await addEpisode(fixture, ordinal: 1),
            try await addEpisode(fixture, ordinal: 2),
        ])
        let records = try recordsDirectory("progress")
        defer { try? FileManager.default.removeItem(at: records) }
        let sender = StubSender(outcomes: [
            .respond(LabellerResponse(text: Self.goodReply, usage: LabellerUsage())),
            .respond(LabellerResponse(text: Self.goodReply, usage: LabellerUsage())),
        ])
        let recorder = makeRecorder(fixture: fixture, sender: sender, recordsDirectory: records)
        let backfill = makeBackfill(fixture: fixture, recorder: recorder,
                                    worker: CuesExportWorker(script: .export, exports: episodes))

        let log = ProgressLog()
        let summary = await backfill.run { log.append($0) }

        #expect(summary == LabellerBackfill.Summary(recorded: 2, failed: 0, remaining: 0, ending: .finished))
        let progress = log.all
        #expect(progress.map(\.done) == [0, 1, 2], "once before the first episode, once after each")
        #expect(progress.allSatisfy { $0.total == 2 })
        #expect(progress.map(\.recorded) == [0, 1, 2])
        #expect(progress.allSatisfy { $0.failed == 0 })
    }

    // MARK: The store query

    @Test func theQueryPrefersTheNewestAttemptThatCarriesWorkerResultEvidence() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let prepared = try await addEpisode(fixture, ordinal: 1, sequence: 1, outcome: "cut",
                                            workerResult: true, removed: (3, 7.5))
        try await addEpisode(fixture, ordinal: 1, sequence: 2, outcome: "noAds",
                             workerResult: false, removed: (2, 6))

        let candidates = try await fixture.store.labellerBackfillCandidates(sourceHashes: [prepared.sourceHash])

        let candidate = try #require(candidates.first)
        #expect(candidate.episodeID == prepared.episode.itemID)
        #expect(candidate.sourceHash == prepared.sourceHash)
        #expect(candidate.engineOutcome == "cut", "the older attempt is the newest that carries the worker result")
        #expect(candidate.engineVersion == Self.engineVersion)
        #expect(candidate.engineCutSpans == [LabellerShadowRecorder.ShadowSpan(start: 3, end: 7.5)])
        #expect(candidate.timelineEndSeconds == 12)
    }

    @Test func theQueryTakesTheNewestWhenBothAttemptsCarryWorkerResultEvidence() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let prepared = try await addEpisode(fixture, ordinal: 1, sequence: 1, outcome: "cut",
                                            workerResult: true, removed: (3, 7.5))
        try await addEpisode(fixture, ordinal: 1, sequence: 2, outcome: "noAds",
                            workerResult: true, removed: (2, 6))

        let candidates = try await fixture.store.labellerBackfillCandidates(sourceHashes: [prepared.sourceHash])

        let candidate = try #require(candidates.first)
        #expect(candidate.engineOutcome == "noAds")
        #expect(candidate.engineCutSpans == [LabellerShadowRecorder.ShadowSpan(start: 2, end: 6)])
    }

    @Test func theQueryFallsBackToUnknownWhenNoAttemptCarriesWorkerResultEvidence() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let prepared = try await addEpisode(fixture, ordinal: 1, outcome: "cut", workerResult: false)

        let candidates = try await fixture.store.labellerBackfillCandidates(sourceHashes: [prepared.sourceHash])

        let candidate = try #require(candidates.first)
        #expect(candidate.engineOutcome == "unknown")
        #expect(candidate.engineVersion == Self.engineVersion)
        #expect(candidate.engineCutSpans == [LabellerShadowRecorder.ShadowSpan(start: 3, end: 7.5)],
                "the timeline still comes from the chosen attempt")
        #expect(candidate.timelineEndSeconds == 12)
    }

    @Test func theQueryFallsBackToARevisionWhoseContentHashWasExported() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let prepared = try await addEpisode(fixture, ordinal: 1)
        // The episode's ready revision carries a different hash than its attempt.
        let revisionHash = "sha256:" + String(repeating: "b", count: 60) + String(format: "%04d", 1)

        let candidates = try await fixture.store.labellerBackfillCandidates(sourceHashes: [revisionHash])

        let candidate = try #require(candidates.first)
        #expect(candidate.episodeID == prepared.episode.itemID)
        #expect(candidate.sourceHash == revisionHash)
        #expect(candidate.engineOutcome == "unknown")
        #expect(candidate.engineVersion == nil)
        #expect(candidate.engineCutSpans.isEmpty)
        #expect(candidate.timelineEndSeconds == 0)
    }

    @Test func theQueryExcludesRetiredEpisodes() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let prepared = try await addEpisode(fixture, ordinal: 1)
        try await fixture.store.retireEpisode(prepared.episode.itemID)

        let candidates = try await fixture.store.labellerBackfillCandidates(sourceHashes: [prepared.sourceHash])

        #expect(candidates.isEmpty)
    }
}
