import CryptoKit
import Foundation
import SwiftData
import Testing
import WiltedDomain
@testable import WiltedProducer

/// Doubles, the fixture and helpers for the labeller backfill tests. Kept in
/// an extension so the test file stays under the file-size ceiling.
extension LabellerBackfillTests {
    /// One episode the fixture journalled a finished attempt for.
    struct PreparedEpisode {
        let episode: PodcastEpisode
        let sourceHash: String
        let cues: [LabellerCue]
    }

    // MARK: Doubles

    /// Stands in for the labelling client: scripted outcomes, one per call.
    final class StubSender: LabellerSending, @unchecked Sendable {
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
    final class CuesExportWorker: PodcastPipelineRunning, @unchecked Sendable {
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
    final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [LabellerBackfill.Progress] = []

        func append(_ value: LabellerBackfill.Progress) { lock.withLock { values.append(value) } }
        var all: [LabellerBackfill.Progress] { lock.withLock { values } }
    }

    // MARK: Fixture

    struct Fixture {
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
    func addEpisode(
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

    func insertJournal(
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

    func makeRecorder(
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

    func makeBackfill(
        fixture: Fixture, recorder: LabellerShadowRecorder, worker: CuesExportWorker
    ) -> LabellerBackfill {
        LabellerBackfill(store: fixture.store, recorder: recorder, runner: worker,
                         workDirectory: fixture.workDirectory)
    }

    func recordsDirectory(_ name: String) throws -> URL {
        let url = OwnedTestTemp.root
            .appendingPathComponent("LabellerBackfillTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func exportDirectory(_ fixture: Fixture) -> URL {
        fixture.workDirectory.appendingPathComponent("wilted-pipeline", isDirectory: true)
            .appendingPathComponent("labeller-backfill", isDirectory: true)
    }

    func recordURL(_ directory: URL, episodeID: ItemID) -> URL {
        directory.appendingPathComponent(LabellerShadowRecorder.recordFileName(for: episodeID.rawValue))
    }

    func readRecord(_ directory: URL, episodeID: ItemID) throws -> [String: Any] {
        let data = try Data(contentsOf: recordURL(directory, episodeID: episodeID))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Writes a record file as an earlier run would have left it.
    func writeRecord(_ directory: URL, episodeID: ItemID, route: String,
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

    func rowCount<T: PersistentModel>(_: T.Type, in store: LocalLibraryStore) throws -> Int {
        try ModelContext(store.container).fetchCount(FetchDescriptor<T>())
    }

    /// The episodes in the order the backfill labels them: episode-ID order.
    func labelledFirst(_ episodes: [PreparedEpisode]) -> [PreparedEpisode] {
        episodes.sorted { $0.episode.itemID.rawValue < $1.episode.itemID.rawValue }
    }
}
