import CryptoKit
import Foundation
import Testing
import WiltedDomain
@testable import WiltedProducer

@Suite("Labeller shadow recorder")
struct LabellerShadowRecorderTests {
    private typealias Fixture = PodcastPreparationPipelineTests.Fixture

    private static let feedURL = URL(string: "https://feeds.example.test/show.xml")!
    private static let feedID = try! ItemID.derivePodcastFeed(from: feedURL)
    private static let showTitle = "Invented Garden Show"
    private static let key = "invented-key-0123456789abcdef"
    private static let cueTexts = [
        "Welcome to the invented garden show.",
        "This break is brought to you by Fizzbolt.",
        "Fizzbolt makes invented widgets.",
        "Back to the show.",
    ]
    private static let goodReply =
        #"{"breaks":[{"startSegment":1,"endSegment":2,"kind":"sponsor","label":"must-cut","advertisers":["Fizzbolt"]}]}"#
    private static let garbageReply = "I cannot answer in JSON."

    // MARK: Doubles and fixtures

    /// Stands in for the labelling client: scripted outcomes, one per call,
    /// and a count of the calls (each stands for one HTTP request).
    private final class StubSender: LabellerSending, @unchecked Sendable {
        enum Outcome {
            case respond(LabellerResponse)
            case fail(any Error)
            case hang
        }

        private let lock = NSLock()
        private var outcomes: [Outcome]
        private var sent = 0
        private var prompts: [String] = []

        init(outcomes: [Outcome]) { self.outcomes = outcomes }

        var requestCount: Int { lock.withLock { sent } }
        var sentPrompts: [String] { lock.withLock { prompts } }

        func send(
            _ request: LabellerRequest,
            onRequestStarted: @escaping @Sendable () -> Void,
            onProgress: @escaping @Sendable (LabellerProgress) -> Void
        ) async throws -> LabellerResponse {
            let index = lock.withLock {
                prompts.append(request.prompt)
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

    /// One full pipeline run with everything shadow needs attached, plus cleanup.
    private struct Run {
        let fixture: Fixture
        let defaults: UserDefaults
        let defaultsName: String
        let recordsDirectory: URL
        let sender: StubSender
        let result: PodcastPreparationResult
        let ready: StoredAudioRevision
        let workerRequest: [String: Any]
        let cueDigest: String

        func cleanup() {
            fixture.remove()
            defaults.removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: recordsDirectory)
        }
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let name = "LabellerShadowRecorderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (defaults, name)
    }

    private func makeRecorder(
        defaults: UserDefaults,
        sender: any LabellerSending,
        recordsDirectory: URL,
        shadow: Bool,
        confirmed: Bool = true,
        dailyCap: Int? = nil
    ) -> LabellerShadowRecorder {
        let preferences = AdLabellerPreferences(preferences: defaults)
        preferences.isEnabled = true
        preferences.isShadow = shadow
        if let dailyCap { preferences.dailyCap = dailyCap }
        if confirmed { preferences.setConfirmed(feedID: Self.feedID.rawValue, true) }
        return LabellerShadowRecorder(
            preferences: preferences,
            counter: LabellerRequestCounter(preferences: defaults),
            keyStore: InMemoryLabellerKeyStore(key: Self.key),
            sender: sender,
            recordsDirectory: recordsDirectory,
            now: { Date(timeIntervalSince1970: 1_700_000_300) }
        )
    }

    private func saveFeed(in store: LocalLibraryStore) async throws {
        try await store.save(feed: PodcastFeed(
            itemID: Self.feedID,
            canonicalURL: Self.feedURL,
            title: Self.showTitle,
            createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        ))
    }

    private struct CueFile {
        let path: String
        let digest: String
    }

    /// A cue file in the worker's format: a JSON array of `{"id","start","end","text"}`.
    private func writeCueFile(to workDirectory: URL) throws -> CueFile {
        let cues = [
            LabellerCue(id: 0, start: 0, end: 3, text: Self.cueTexts[0]),
            LabellerCue(id: 1, start: 3, end: 7.5, text: Self.cueTexts[1]),
            LabellerCue(id: 2, start: 7.5, end: 10, text: Self.cueTexts[2]),
            LabellerCue(id: 3, start: 10, end: 12, text: Self.cueTexts[3]),
        ]
        let data = try JSONEncoder().encode(cues)
        let url = workDirectory.appendingPathComponent("labeller-cues.json")
        try data.write(to: url)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return CueFile(path: url.path, digest: digest)
    }

    private func cuttingResponse(fixture: Fixture, cuePath: String, cueDigest: String) -> [String: Any] {
        var response = Fixture.cuttingStubResponse()
        response["labellerCuesPath"] = cuePath
        response["labellerCuesDigest"] = cueDigest
        return response
    }

    private func pipeline(
        _ fixture: Fixture, runner: some PodcastPipelineRunning,
        shadowRecorder: LabellerShadowRecorder?
    ) -> PodcastPreparationPipeline {
        PodcastPreparationPipeline(
            store: fixture.store,
            workDirectory: fixture.workDirectory,
            runner: runner,
            now: { Date(timeIntervalSince1970: 1_700_000_200) },
            appVersion: nil,
            engineVersion: PodcastPreparationPipeline.semanticVersion,
            shadowRecorder: shadowRecorder
        )
    }

    private func runPipeline(
        shadow: Bool,
        confirmed: Bool = true,
        dailyCap: Int? = nil,
        cueDigest: String? = nil,
        sender: StubSender
    ) async throws -> Run {
        let fixture = try await Fixture()
        try await saveFeed(in: fixture.store)
        let (defaults, defaultsName) = makeDefaults()
        let recordsDirectory = try Fixture.temporaryDirectory()
        let recorder = makeRecorder(defaults: defaults, sender: sender, recordsDirectory: recordsDirectory,
                                     shadow: shadow, confirmed: confirmed, dailyCap: dailyCap)
        let cueFile = try writeCueFile(to: fixture.workDirectory)
        let stub = WorkerStub(
            response: cuttingResponse(fixture: fixture, cuePath: cueFile.path,
                                     cueDigest: cueDigest ?? cueFile.digest),
            writesCutAudio: Fixture.cuttingAudio)
        let result = try await pipeline(fixture, runner: stub, shadowRecorder: recorder)
            .prepare(episodeID: fixture.episodeID)
        await recorder.waitForIdle()
        let ready = try #require(try await fixture.store.readyRevision(for: fixture.episodeID))
        let requestData = try #require(await stub.lastRequest())
        let request = try #require(try JSONSerialization.jsonObject(with: requestData) as? [String: Any])
        return Run(fixture: fixture, defaults: defaults, defaultsName: defaultsName,
                   recordsDirectory: recordsDirectory, sender: sender, result: result,
                   ready: ready, workerRequest: request, cueDigest: cueFile.digest)
    }

    private func readRecord(directory: URL, episodeID: ItemID) throws -> [String: Any] {
        let url = directory.appendingPathComponent(LabellerShadowRecorder.recordFileName(for: episodeID.rawValue))
        let data = try Data(contentsOf: url)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func readAttempts(directory: URL) throws -> [[String: Any]] {
        let url = directory.appendingPathComponent(LabellerShadowRecorder.attemptsFileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let text = try String(contentsOf: url, encoding: .utf8)
        var lines: [[String: Any]] = []
        for line in text.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) else { continue }
            if let fields = object as? [String: Any] { lines.append(fields) }
        }
        return lines
    }

    // MARK: Tests

    /// Shadow changes nothing the pipeline commits, and leaves a comparison
    /// record beside the engine's result.
    @Test func shadowLeavesTheCommitUnchangedAndRecordsTheComparison() async throws {
        let response = LabellerResponse(
            text: Self.goodReply,
            usage: LabellerUsage(promptTokens: 100, completionTokens: 50, reasoningTokens: 20))
        let off = try await runPipeline(shadow: false, sender: StubSender(outcomes: [.respond(response)]))
        defer { off.cleanup() }
        let on = try await runPipeline(shadow: true, sender: StubSender(outcomes: [.respond(response)]))
        defer { on.cleanup() }

        #expect(on.result.adRemovalOutcome == off.result.adRemovalOutcome)
        #expect(on.result.revision.revisionID == off.result.revision.revisionID)
        #expect(on.result.mediaURL.lastPathComponent == off.result.mediaURL.lastPathComponent)
        #expect(on.ready.revision.revisionID == off.ready.revision.revisionID)
        #expect(on.ready.revision.durationSeconds == off.ready.revision.durationSeconds)
        #expect(on.ready.revision.contentHash == off.ready.revision.contentHash)
        #expect(on.ready.mediaURL.lastPathComponent == off.ready.mediaURL.lastPathComponent)
        #expect(on.workerRequest["emitLabellerCues"] as? Bool == true)
        #expect(off.workerRequest["emitLabellerCues"] == nil)

        let offRecord = off.recordsDirectory
            .appendingPathComponent(LabellerShadowRecorder.recordFileName(for: off.fixture.episodeID.rawValue))
        #expect(FileManager.default.fileExists(atPath: offRecord.path) == false)
        #expect(try readAttempts(directory: off.recordsDirectory).isEmpty)

        let record = try readRecord(directory: on.recordsDirectory, episodeID: on.fixture.episodeID)
        #expect(record["schemaVersion"] as? Int == 1)
        #expect(record["route"] as? String == "remote")
        #expect(record["engineOutcome"] as? String == "cut")
        #expect(record["failureKind"] == nil)
        #expect(record["promptTokens"] as? Int == 100)
        #expect(record["completionTokens"] as? Int == 50)
        #expect(record["reasoningTokens"] as? Int == 20)
        #expect(record["requestCount"] as? Int == 1)
        #expect(record["cueCount"] as? Int == 4)
        #expect(record["cuesDigest"] as? String == on.cueDigest)
        #expect(record["promptVersion"] as? String == EpisodeLabeller.promptVersion)
        #expect(record["modelID"] as? String == AdLabellerPreferences.defaultModelID)
        #expect(record["level"] as? String == AdLabellerPreferences.defaultLevel)

        let spans = try #require(record["engineCutSpans"] as? [[String: Any]])
        #expect(spans.count == 1)
        #expect(spans.first?["start"] as? Double == 3.0)
        #expect(spans.first?["end"] as? Double == 7.5)

        let proposed = try #require(record["proposedBreaks"] as? [[String: Any]])
        #expect(proposed.count == 1)
        #expect(proposed.first?["start"] as? Double == 3.0)
        #expect(proposed.first?["end"] as? Double == 10.0)
        #expect(proposed.first?["startCue"] as? Int == 1)
        #expect(proposed.first?["endCue"] as? Int == 2)
        #expect(proposed.first?["kind"] as? String == "sponsor")
        #expect(proposed.first?["label"] as? String == "must-cut")
        #expect(proposed.first?["advertisers"] as? [String] == ["Fizzbolt"])
        #expect((record["rejectedBreaks"] as? [[String: Any]])?.isEmpty == true)

        let attempts = try readAttempts(directory: on.recordsDirectory)
        #expect(attempts.count == 1)
        #expect(attempts.first?["outcome"] as? String == "recorded")
        #expect(attempts.first?["episodeID"] as? String == on.fixture.episodeID.rawValue)
    }

    @Test func aSenderFailureIsRecordedAndLeavesTheCommitUnchanged() async throws {
        let run = try await runPipeline(
            shadow: true,
            sender: StubSender(outcomes: [.fail(LabellerFailure.rateLimited(retryAfter: nil))]))
        defer { run.cleanup() }

        #expect(run.result.adRemovalOutcome == "cut")
        #expect(run.ready.revision.revisionID == run.result.revision.revisionID)
        #expect(run.sender.requestCount == 1)

        let record = try readRecord(directory: run.recordsDirectory, episodeID: run.fixture.episodeID)
        #expect(record["route"] as? String == "remote")
        #expect(record["failureKind"] as? String == "rate-limited")
        #expect(record["proposedBreaks"] == nil)
        #expect(record["requestCount"] as? Int == 1)
        #expect(try readAttempts(directory: run.recordsDirectory).first?["outcome"] as? String == "rate-limited")
    }

    @Test func aLocalRouteRecordsTheReasonAndNoBreakFields() async throws {
        let run = try await runPipeline(
            shadow: true, confirmed: false,
            sender: StubSender(outcomes: [.respond(LabellerResponse(text: Self.goodReply, usage: LabellerUsage()))]))
        defer { run.cleanup() }

        #expect(run.sender.requestCount == 0)
        let record = try readRecord(directory: run.recordsDirectory, episodeID: run.fixture.episodeID)
        #expect(record["route"] as? String == "local")
        #expect(record["routeReason"] as? String == "notConfirmed")
        #expect(record["proposedBreaks"] == nil)
        #expect(record["rejectedBreaks"] == nil)
        #expect(record["failureKind"] == nil)
        #expect(record["engineOutcome"] as? String == "cut")
        #expect(try readAttempts(directory: run.recordsDirectory).first?["outcome"] as? String == "local")
    }

    @Test func withTheGlobalSwitchOffNothingIsExportedSentOrWritten() async throws {
        let (defaults, name) = makeDefaults()
        let directory = OwnedTestTemp.root
            .appendingPathComponent("LabellerShadowRecorderTests-off-\(UUID().uuidString)", isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: directory)
        }
        let sender = StubSender(outcomes: [.respond(LabellerResponse(text: Self.goodReply, usage: LabellerUsage()))])
        let recorder = makeRecorder(defaults: defaults, sender: sender, recordsDirectory: directory, shadow: true)
        AdLabellerPreferences(preferences: defaults).isEnabled = false

        #expect(await recorder.wantsCues == false, "no cue export is requested while the switch is off")
        await recorder.schedule(LabellerShadowRecorder.ShadowInput(
            episodeID: "episode-off", feedID: Self.feedID.rawValue, feedURL: Self.feedURL,
            feedTitle: Self.showTitle, audioURL: nil, durationSeconds: 600, cuesPath: nil, cuesDigest: nil,
            engineOutcome: "cut", engineCutSpans: []))
        await recorder.waitForIdle()

        #expect(sender.requestCount == 0)
        #expect(!FileManager.default.fileExists(atPath: directory.path), "no record and no attempts line")
    }

    @Test func aDigestMismatchRecordsCuesUnavailableAndSendsNothing() async throws {
        let run = try await runPipeline(
            shadow: true, cueDigest: String(repeating: "0", count: 64),
            sender: StubSender(outcomes: [.respond(LabellerResponse(text: Self.goodReply, usage: LabellerUsage()))]))
        defer { run.cleanup() }

        #expect(run.sender.requestCount == 0)
        let record = try readRecord(directory: run.recordsDirectory, episodeID: run.fixture.episodeID)
        #expect(record["failureKind"] as? String == "cuesUnavailable")
        #expect(record["proposedBreaks"] == nil)
        #expect(record["requestCount"] as? Int == 0)
        #expect(try readAttempts(directory: run.recordsDirectory).first?["outcome"] as? String == "cuesUnavailable")
    }

    @Test func anUnusableAnswerRetriesOnceAndCountsTwoRequests() async throws {
        let sender = StubSender(outcomes: [
            .respond(LabellerResponse(text: Self.garbageReply,
                                      usage: LabellerUsage(promptTokens: 10, completionTokens: 1, reasoningTokens: 3))),
            .respond(LabellerResponse(text: Self.goodReply,
                                      usage: LabellerUsage(promptTokens: 10, completionTokens: 5, reasoningTokens: 2))),
        ])
        let run = try await runPipeline(shadow: true, sender: sender)
        defer { run.cleanup() }

        #expect(sender.requestCount == 2)
        #expect(LabellerRequestCounter(preferences: run.defaults).count == 2)
        let record = try readRecord(directory: run.recordsDirectory, episodeID: run.fixture.episodeID)
        #expect(record["requestCount"] as? Int == 2)
        #expect(record["failureKind"] == nil)
        #expect((record["proposedBreaks"] as? [[String: Any]])?.count == 1)
        // Both requests were billed, so the record counts both replies' tokens.
        #expect(record["promptTokens"] as? Int == 20)
        #expect(record["completionTokens"] as? Int == 6)
        #expect(record["reasoningTokens"] as? Int == 5)
    }

    @Test func recordedAdvertiserNamesAreShortSingleLinesAndFew() {
        let long = String(repeating: "x", count: 200)
        let kept = LabellerShadowRecorder.recordedAdvertisers(
            ["  Acme  ", "", "two\nlines", long] + Array(repeating: "more", count: 10))
        #expect(kept.count == 7)
        #expect(Array(kept.prefix(3)) == ["Acme", "two lines", String(long.prefix(60))])
        #expect(LabellerShadowRecorder.summed(LabellerUsage(), LabellerUsage()).promptTokens == nil)
    }

    @Test func atTheDailyCapItDoesNotRetry() async throws {
        let sender = StubSender(outcomes: [
            .respond(LabellerResponse(text: Self.garbageReply, usage: LabellerUsage())),
            .respond(LabellerResponse(text: Self.goodReply, usage: LabellerUsage())),
        ])
        let run = try await runPipeline(shadow: true, dailyCap: 1, sender: sender)
        defer { run.cleanup() }

        #expect(sender.requestCount == 1)
        let record = try readRecord(directory: run.recordsDirectory, episodeID: run.fixture.episodeID)
        #expect(record["failureKind"] as? String == "unusable-answer")
        #expect(record["requestCount"] as? Int == 1)
        #expect(record["proposedBreaks"] == nil)
    }

    @Test func noRecordOrAttemptLineContainsCueTextThePromptOrTheKey() async throws {
        let run = try await runPipeline(
            shadow: true,
            sender: StubSender(outcomes: [.respond(LabellerResponse(text: Self.goodReply, usage: LabellerUsage()))]))
        defer { run.cleanup() }

        // The prompt really did carry the cue text and the show title, and the
        // key really is stored, so their absence from the files is meaningful.
        #expect(run.sender.sentPrompts.first?.contains(Self.cueTexts[1]) == true)
        #expect(run.sender.sentPrompts.first?.contains(Self.showTitle) == true)

        let recordText = try String(
            contentsOf: run.recordsDirectory.appendingPathComponent(
                LabellerShadowRecorder.recordFileName(for: run.fixture.episodeID.rawValue)),
            encoding: .utf8)
        let attemptsText = try String(
            contentsOf: run.recordsDirectory.appendingPathComponent(LabellerShadowRecorder.attemptsFileName),
            encoding: .utf8)
        for text in [recordText, attemptsText] {
            for cue in Self.cueTexts {
                #expect(text.contains(cue) == false)
            }
            #expect(text.contains(Self.key) == false)
            #expect(text.contains(Self.showTitle) == false)
            #expect(text.contains("TRANSCRIPT:") == false)
            #expect(text.contains("#1 [3.00-7.50]") == false)
        }
    }

    @Test func cancelAllStopsARunningTaskAndWritesNothing() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let (defaults, defaultsName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let recordsDirectory = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: recordsDirectory) }
        let sender = StubSender(outcomes: [.hang])
        let recorder = makeRecorder(defaults: defaults, sender: sender,
                                     recordsDirectory: recordsDirectory, shadow: true)
        let cueFile = try writeCueFile(to: fixture.workDirectory)

        await recorder.schedule(LabellerShadowRecorder.ShadowInput(
            episodeID: fixture.episodeID.rawValue,
            feedID: Self.feedID.rawValue,
            feedURL: Self.feedURL,
            feedTitle: Self.showTitle,
            audioURL: URL(string: "https://cdn.example.test/e1.mp3"),
            durationSeconds: 12,
            cuesPath: cueFile.path,
            cuesDigest: cueFile.digest,
            engineOutcome: "cut",
            engineCutSpans: [LabellerShadowRecorder.ShadowSpan(start: 3, end: 7.5)]
        ))

        // Wait until the request has started, then cancel it mid-flight.
        var polls = 0
        while sender.requestCount == 0, polls < 5_000 {
            try await Task.sleep(for: .milliseconds(2))
            polls += 1
        }
        #expect(sender.requestCount == 1)
        await recorder.cancelAll()
        await recorder.waitForIdle()

        let recordURL = recordsDirectory.appendingPathComponent(
            LabellerShadowRecorder.recordFileName(for: fixture.episodeID.rawValue))
        #expect(FileManager.default.fileExists(atPath: recordURL.path) == false)
        #expect(try readAttempts(directory: recordsDirectory).isEmpty)
    }

    // MARK: Awaited labelling

    /// A directory for tests that need no pipeline fixture.
    private func makeDirectory(_ name: String) throws -> URL {
        let url = OwnedTestTemp.root
            .appendingPathComponent("LabellerShadowRecorderTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func labelInput(episodeID: String, cueFile: CueFile?) -> LabellerShadowRecorder.ShadowInput {
        LabellerShadowRecorder.ShadowInput(
            episodeID: episodeID,
            feedID: Self.feedID.rawValue,
            feedURL: Self.feedURL,
            feedTitle: Self.showTitle,
            audioURL: URL(string: "https://cdn.example.test/e1.mp3"),
            durationSeconds: 12,
            cuesPath: cueFile?.path,
            cuesDigest: cueFile?.digest,
            engineOutcome: "cut",
            engineCutSpans: [LabellerShadowRecorder.ShadowSpan(start: 3, end: 7.5)]
        )
    }

    @Test func labelWritesNothingForInactiveAndNotRouted() async throws {
        let directory = try makeDirectory("label-local")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sender = StubSender(outcomes: [.respond(LabellerResponse(text: Self.goodReply, usage: LabellerUsage()))])
        let cueFile = try writeCueFile(to: directory)
        let input = labelInput(episodeID: "episode-label", cueFile: cueFile)

        // Inactive: the global switch is off.
        let (offDefaults, offName) = makeDefaults()
        defer { offDefaults.removePersistentDomain(forName: offName) }
        let off = makeRecorder(defaults: offDefaults, sender: sender, recordsDirectory: directory, shadow: true)
        AdLabellerPreferences(preferences: offDefaults).isEnabled = false
        #expect(await off.label(input) == .inactive)
        #expect(await off.localReason(for: input) == .switchOff)

        // Not routed: the show is not confirmed for online labelling.
        let (localDefaults, localName) = makeDefaults()
        defer { localDefaults.removePersistentDomain(forName: localName) }
        let local = makeRecorder(defaults: localDefaults, sender: sender, recordsDirectory: directory,
                                  shadow: true, confirmed: false)
        #expect(await local.label(input) == .notRouted(.notConfirmed))
        #expect(await local.localReason(for: input) == .notConfirmed)

        #expect(sender.requestCount == 0, "neither outcome sends anything")
        #expect(try readAttempts(directory: directory).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory
            .appendingPathComponent(LabellerShadowRecorder.recordFileName(for: "episode-label")).path))
    }

    /// The owner's name for a show decides keep-local but is never part of the request.
    @Test func theOwnersShowNameKeepsItLocalAndNeverEntersThePrompt() async throws {
        let directory = try makeDirectory("label-custom-name")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (defaults, defaultsName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let sender = StubSender(outcomes: [.respond(LabellerResponse(text: Self.goodReply, usage: LabellerUsage()))])
        let recorder = makeRecorder(defaults: defaults, sender: sender, recordsDirectory: directory, shadow: true)
        let cueFile = try writeCueFile(to: directory)

        var paid = labelInput(episodeID: "episode-paid", cueFile: cueFile)
        paid.feedCustomTitle = "Garden (ad-free)"
        #expect(await recorder.localReason(for: paid) == .privateTitle)
        #expect(await recorder.label(paid) == .notRouted(.privateTitle))
        #expect(sender.requestCount == 0)

        var renamed = labelInput(episodeID: "episode-renamed", cueFile: cueFile)
        renamed.feedCustomTitle = "Zebra Nickname"
        #expect(await recorder.label(renamed) == .recorded)
        #expect(sender.sentPrompts.count == 1)
        #expect(sender.sentPrompts.allSatisfy { $0.contains(Self.showTitle) && !$0.contains("Zebra Nickname") })
    }

    @Test func labelRecordsARemoteComparisonAndReturnsRecorded() async throws {
        let directory = try makeDirectory("label-recorded")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (defaults, defaultsName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let sender = StubSender(outcomes: [.respond(LabellerResponse(text: Self.goodReply, usage: LabellerUsage()))])
        let recorder = makeRecorder(defaults: defaults, sender: sender, recordsDirectory: directory, shadow: true)
        let cueFile = try writeCueFile(to: directory)

        let outcome = await recorder.label(labelInput(episodeID: "episode-label", cueFile: cueFile))
        #expect(outcome == .recorded)
        #expect(sender.requestCount == 1)
        #expect(await recorder.localReason(for: labelInput(episodeID: "episode-label", cueFile: cueFile)) == nil)

        let record = try readRecord(directory: directory, episodeID: try ItemID(rawValue: "episode-label"))
        #expect(record["route"] as? String == "remote")
        #expect(record["failureKind"] == nil)
        #expect((record["proposedBreaks"] as? [[String: Any]])?.count == 1)
        #expect(try readAttempts(directory: directory).first?["outcome"] as? String == "recorded")
    }

    @Test func labelReturnsTheFailureKindItRecords() async throws {
        let directory = try makeDirectory("label-failed")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (defaults, defaultsName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let sender = StubSender(outcomes: [.fail(LabellerFailure.rateLimited(retryAfter: nil))])
        let recorder = makeRecorder(defaults: defaults, sender: sender, recordsDirectory: directory, shadow: true)
        let cueFile = try writeCueFile(to: directory)

        let outcome = await recorder.label(labelInput(episodeID: "episode-label", cueFile: cueFile))
        #expect(outcome == .failed(kind: "rate-limited"))
        let record = try readRecord(directory: directory, episodeID: try ItemID(rawValue: "episode-label"))
        #expect(record["failureKind"] as? String == "rate-limited")
        #expect(try readAttempts(directory: directory).first?["outcome"] as? String == "rate-limited")
    }

    @Test func labelReportsCuesUnavailableForAMissingCueFile() async throws {
        let directory = try makeDirectory("label-cues")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (defaults, defaultsName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let sender = StubSender(outcomes: [.respond(LabellerResponse(text: Self.goodReply, usage: LabellerUsage()))])
        let recorder = makeRecorder(defaults: defaults, sender: sender, recordsDirectory: directory, shadow: true)

        let outcome = await recorder.label(labelInput(episodeID: "episode-label", cueFile: nil))
        #expect(outcome == .failed(kind: "cuesUnavailable"))
        #expect(sender.requestCount == 0)
        let record = try readRecord(directory: directory, episodeID: try ItemID(rawValue: "episode-label"))
        #expect(record["failureKind"] as? String == "cuesUnavailable")
        #expect(try readAttempts(directory: directory).first?["outcome"] as? String == "cuesUnavailable")
    }

    @Test func labelWritesNothingWhenCancelled() async throws {
        let directory = try makeDirectory("label-cancel")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (defaults, defaultsName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let sender = StubSender(outcomes: [.hang])
        let recorder = makeRecorder(defaults: defaults, sender: sender, recordsDirectory: directory, shadow: true)
        let cueFile = try writeCueFile(to: directory)

        let task = Task { await recorder.label(labelInput(episodeID: "episode-label", cueFile: cueFile)) }
        var polls = 0
        while sender.requestCount == 0, polls < 5_000 {
            try await Task.sleep(for: .milliseconds(2))
            polls += 1
        }
        task.cancel()
        let outcome = await task.value
        #expect(outcome == .cancelled)
        #expect(!FileManager.default.fileExists(atPath: directory
            .appendingPathComponent(LabellerShadowRecorder.recordFileName(for: "episode-label")).path))
        #expect(try readAttempts(directory: directory).isEmpty)
    }

    @Test func liveScheduleRecordsDoNotGainSourceOrEngineVersion() async throws {
        let directory = try makeDirectory("label-live")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (defaults, defaultsName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let sender = StubSender(outcomes: [.respond(LabellerResponse(text: Self.goodReply, usage: LabellerUsage()))])
        let recorder = makeRecorder(defaults: defaults, sender: sender, recordsDirectory: directory, shadow: true)
        let cueFile = try writeCueFile(to: directory)

        await recorder.schedule(labelInput(episodeID: "episode-live", cueFile: cueFile))
        await recorder.waitForIdle()

        let record = try readRecord(directory: directory, episodeID: try ItemID(rawValue: "episode-live"))
        #expect(record["source"] == nil, "live records carry no source")
        #expect(record["engineVersion"] == nil, "live records carry no engine version")
    }

    @Test func requestsRemainingIsTheCapMinusTodayCount() async throws {
        let (defaults, defaultsName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let directory = try makeDirectory("label-cap")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sender = StubSender(outcomes: [.respond(LabellerResponse(text: Self.goodReply, usage: LabellerUsage()))])
        let recorder = makeRecorder(defaults: defaults, sender: sender, recordsDirectory: directory,
                                     shadow: true, dailyCap: 2)
        #expect(await recorder.requestsRemaining == 2)
        _ = await recorder.label(labelInput(episodeID: "episode-cap", cueFile: try writeCueFile(to: directory)))
        #expect(await recorder.requestsRemaining == 1)
    }

    @Test func hasLabelledRecordIsTrueOnlyForARemoteRecordWithoutFailure() async throws {
        let directory = try makeDirectory("label-has")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (defaults, defaultsName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let cueFile = try writeCueFile(to: directory)
        let episodeID = try ItemID(rawValue: "episode-has")

        // No record at all.
        let absent = makeRecorder(defaults: defaults, sender: StubSender(outcomes: []),
                                  recordsDirectory: directory, shadow: true)
        #expect(await absent.hasLabelledRecord(episodeID: episodeID.rawValue) == false)

        // A local record is not a labelled one.
        let local = makeRecorder(defaults: defaults, sender: StubSender(outcomes: []),
                                 recordsDirectory: directory, shadow: true, confirmed: false)
        await local.schedule(labelInput(episodeID: episodeID.rawValue, cueFile: cueFile))
        #expect(await local.hasLabelledRecord(episodeID: episodeID.rawValue) == false)

        // A failed remote record is not a labelled one.
        let failed = makeRecorder(defaults: defaults,
                                  sender: StubSender(outcomes: [.fail(LabellerFailure.keyRejected)]),
                                  recordsDirectory: directory, shadow: true)
        _ = await failed.label(labelInput(episodeID: episodeID.rawValue, cueFile: cueFile))
        #expect(await failed.hasLabelledRecord(episodeID: episodeID.rawValue) == false)

        // A recorded comparison is.
        let recorded = makeRecorder(defaults: defaults,
                                     sender: StubSender(outcomes: [.respond(LabellerResponse(text: Self.goodReply, usage: LabellerUsage()))]),
                                     recordsDirectory: directory, shadow: true)
        _ = await recorded.label(labelInput(episodeID: episodeID.rawValue, cueFile: cueFile))
        #expect(await recorded.hasLabelledRecord(episodeID: episodeID.rawValue) == true)
    }
}
