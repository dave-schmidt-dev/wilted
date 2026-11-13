import Foundation
import Testing
import WiltedDomain
@testable import WiltedProducer

/// A clock a test moves by hand.
final class RetryTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) { current = start }

    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
    func set(_ date: Date) { lock.withLock { current = date } }
}

extension PodcastPreparationPipelineTests {
    static let retrySequence = 5

    /// A worker whose transcript stage answers with `cue` and whose cut stage cuts. `cutAnswers`
    /// lets a test make the nth cut call fail with a cue mismatch.
    func retryWorker(
        _ cue: (path: String, digest: String, cues: [LabellerCue]), fixture: Fixture,
        cutMismatchOnCall: Int? = nil
    ) -> LabelledStageWorker {
        LabelledStageWorker { request, index in
            switch request["adStage"] as? String {
            case "transcript":
                return ([
                    "ok": true, "adStage": "transcript", "timing": "aligned",
                    "durationSeconds": 12, "labellerCuesPath": cue.path, "labellerCuesDigest": cue.digest,
                ], nil)
            case "cut":
                if index == cutMismatchOnCall {
                    return (["ok": false, "code": "labelled-cues-mismatch", "message": "digest"], nil)
                }
                return (Self.cutResponse(audioPath: request["outputPath"] as? String ?? ""), Fixture.cuttingAudio)
            default:
                return ([
                    "ok": true, "timing": "aligned", "audioPath": request["audioPath"] as? String ?? "",
                    "audioChanged": false, "durationSeconds": 12, "text": "Kept.", "cues": [[String: Any]](),
                    "removedSeconds": 0, "adSegments": [[String: Any]](), "keepIntervals": [[String: Any]](),
                    "report": ["outcome": "disabled", "rawNominations": [[String: Any]]()],
                ], nil)
            }
        }
    }

    func retryPipeline(
        _ fixture: Fixture, runner: some PodcastPipelineRunning, labelling: PodcastLabellingServices,
        clock: RetryTestClock
    ) -> PodcastPreparationPipeline {
        PodcastPreparationPipeline(
            store: fixture.store, workDirectory: fixture.workDirectory, runner: runner,
            now: { clock.now }, appVersion: nil, labelling: labelling)
    }

    /// Puts the episode's ticket in `.running` for `sequence` and returns that generation.
    @discardableResult
    func startTicket(_ fixture: Fixture, sequence: Int = retrySequence, clock: RetryTestClock) async throws
        -> PreparationAttemptIdentity {
        let ticket = try await fixture.store.readmitWorkTicket(
            kind: .podcastPreparation, subjectID: fixture.episodeID.rawValue, requestSequence: sequence,
            to: .running, at: Timestamp(clock.now))
        return try PreparationAttemptIdentity(requestSequence: sequence, attemptCount: ticket.attemptCount)
    }

    func cueFileURL(_ fixture: Fixture, sequence: Int = retrySequence) -> URL {
        fixture.workDirectory.appendingPathComponent("labeller-cues", isDirectory: true)
            .appendingPathComponent("\(fixture.episodeID.rawValue).\(sequence).json")
    }

    func stageCounts(_ worker: LabelledStageWorker) async throws -> (transcript: Int, cut: Int, whole: Int) {
        let stages = try await worker.allRequests().map { try decodeRequest($0)["adStage"] as? String }
        return (stages.filter { $0 == "transcript" }.count, stages.filter { $0 == "cut" }.count,
                stages.filter { $0 == nil }.count)
    }

    func ticket(_ fixture: Fixture) async throws -> WorkTicket {
        try #require(try await fixture.store.workTicket(
            kind: .podcastPreparation, subjectID: fixture.episodeID.rawValue))
    }

    /// Prepares and returns the waiting error it ends with, or nil when it ended another way.
    func prepareExpectingWait(
        _ pipeline: PodcastPreparationPipeline, _ fixture: Fixture, attempt: PreparationAttemptIdentity,
        onStatus: @escaping @Sendable (PodcastPreparationProgress) -> Void = { _ in }
    ) async throws -> PodcastPreparationError? {
        do {
            _ = try await pipeline.prepare(episodeID: fixture.episodeID, attempt: attempt, onStatus: onStatus)
            return nil
        } catch let error as PodcastPreparationError {
            return error
        }
    }

    // MARK: Waiting

    @Test func aWaitKindFailureDefersTheTicketKeepsTheCueFileAndWritesNoTerminalRow() async throws {
        let fixture = try await Fixture()
        let (defaults, defaultsName) = makeDefaults()
        defer { fixture.remove(); defaults.removePersistentDomain(forName: defaultsName) }
        let clock = RetryTestClock()
        let sender = LabellerSenderStub(outcomes: [.fail(.rateLimited(retryAfter: 120))])
        try await saveFeed(in: fixture.store)
        let attempt = try await startTicket(fixture, clock: clock)
        let before = try await ticket(fixture)
        let worker = retryWorker(try writeCueFile(to: fixture.workDirectory), fixture: fixture)
        let status = StatusLog()
        let error = try await prepareExpectingWait(
            retryPipeline(fixture, runner: worker, labelling: configureLabelling(defaults: defaults, sender: sender),
                          clock: clock),
            fixture, attempt: attempt, onStatus: { status.append($0.stage, detail: $0.detail) })

        let resume = clock.now.addingTimeInterval(120)
        #expect(error == .labellerWaiting(until: resume, kind: "rate-limited"))
        let deferred = try await ticket(fixture)
        #expect(deferred.state == .deferred)
        #expect(deferred.nextEligibleAt == Timestamp(resume))
        #expect(deferred.deferralCount == 1)
        #expect(deferred.firstDeferredAt == Timestamp(clock.now))
        #expect(deferred.requestedAt == before.requestedAt)
        #expect(deferred.attemptCount == before.attemptCount)
        #expect(deferred.failureKind == WorkTicketDeferralReason.providerRateLimited.rawValue)
        #expect(FileManager.default.fileExists(atPath: cueFileURL(fixture).path))
        #expect(try await stageCounts(worker) == (1, 0, 0))
        #expect(status.stages.contains("ads.label.wait"))

        let entries = try await fixture.store.preparationJournal(
            for: PodcastPreparationPipeline.requestID(for: fixture.episodeID))
        #expect(!entries.contains { $0.status.terminalResult != nil }, "the generation stays open")
        let wait = try #require(entries.compactMap(\.status.evidence).first { $0.kind == "labeller-wait" })
        #expect(wait.fields["failureKind"] == "rate-limited")
        #expect(wait.fields["nextAttemptAt"] == resume.formatted(.iso8601))
        #expect(wait.fields["deferral"] == "1")
        #expect(!String(describing: entries).contains("Fizzbolt"), "no transcript text is journalled")
    }

    @Test func theRetriedTicketMakesOneRequestWithoutATranscriptRunThenCutsAndDeletesTheFile() async throws {
        let fixture = try await Fixture()
        let (defaults, defaultsName) = makeDefaults()
        defer { fixture.remove(); defaults.removePersistentDomain(forName: defaultsName) }
        let clock = RetryTestClock()
        let sender = LabellerSenderStub(outcomes: [
            .fail(.temporary), .respond(LabellerResponse(text: mustCutReply(), usage: LabellerUsage())),
        ])
        try await saveFeed(in: fixture.store)
        let worker = retryWorker(try writeCueFile(to: fixture.workDirectory), fixture: fixture)
        let pipeline = retryPipeline(
            fixture, runner: worker, labelling: configureLabelling(defaults: defaults, sender: sender), clock: clock)
        _ = try await prepareExpectingWait(pipeline, fixture, attempt: try await startTicket(fixture, clock: clock))
        clock.advance(120)
        let second = try await startTicket(fixture, clock: clock)
        #expect(second.attemptCount == 2)

        let result = try await pipeline.prepare(episodeID: fixture.episodeID, attempt: second)
        #expect(result.adRemovalOutcome == "cut")
        #expect(sender.requestCount == 2)
        #expect(try await stageCounts(worker) == (1, 1, 0), "one transcript run in total")
        #expect(!FileManager.default.fileExists(atPath: cueFileURL(fixture).path))
    }

    @Test(arguments: [false, true])
    func aNewPipelineInstanceReusesTheCueFileOnlyWhileItIsThere(removeFile: Bool) async throws {
        let fixture = try await Fixture()
        let (defaults, defaultsName) = makeDefaults()
        defer { fixture.remove(); defaults.removePersistentDomain(forName: defaultsName) }
        let clock = RetryTestClock()
        let sender = LabellerSenderStub(outcomes: [
            .fail(.temporary), .respond(LabellerResponse(text: mustCutReply(), usage: LabellerUsage())),
        ])
        try await saveFeed(in: fixture.store)
        let worker = retryWorker(try writeCueFile(to: fixture.workDirectory), fixture: fixture)
        let labelling = configureLabelling(defaults: defaults, sender: sender)
        _ = try await prepareExpectingWait(
            retryPipeline(fixture, runner: worker, labelling: labelling, clock: clock), fixture,
            attempt: try await startTicket(fixture, clock: clock))
        if removeFile { try FileManager.default.removeItem(at: cueFileURL(fixture)) }
        clock.advance(120)
        let relaunched = retryPipeline(fixture, runner: worker, labelling: labelling, clock: clock)
        let result = try await relaunched.prepare(
            episodeID: fixture.episodeID, attempt: try await startTicket(fixture, clock: clock))
        #expect(result.adRemovalOutcome == "cut")
        #expect(sender.requestCount == 2)
        #expect(try await stageCounts(worker) == (removeFile ? 2 : 1, 1, 0))
    }

    @Test func aCueFileThatNoLongerMatchesItsDigestIsIgnored() async throws {
        let fixture = try await Fixture()
        let (defaults, defaultsName) = makeDefaults()
        defer { fixture.remove(); defaults.removePersistentDomain(forName: defaultsName) }
        let clock = RetryTestClock()
        let sender = LabellerSenderStub(outcomes: [
            .fail(.temporary), .respond(LabellerResponse(text: mustCutReply(), usage: LabellerUsage())),
        ])
        try await saveFeed(in: fixture.store)
        let worker = retryWorker(try writeCueFile(to: fixture.workDirectory), fixture: fixture)
        let pipeline = retryPipeline(
            fixture, runner: worker, labelling: configureLabelling(defaults: defaults, sender: sender), clock: clock)
        _ = try await prepareExpectingWait(pipeline, fixture, attempt: try await startTicket(fixture, clock: clock))
        try Data(#"{"cues":"AAAA","digest":"00","durationSeconds":12}"#.utf8).write(to: cueFileURL(fixture))
        clock.advance(120)
        _ = try await pipeline.prepare(
            episodeID: fixture.episodeID, attempt: try await startTicket(fixture, clock: clock))
        #expect(try await stageCounts(worker) == (2, 1, 0))
    }

    @Test func aCueMismatchAfterReuseDeletesTheFileAndTakesTheRestartPath() async throws {
        let fixture = try await Fixture()
        let (defaults, defaultsName) = makeDefaults()
        defer { fixture.remove(); defaults.removePersistentDomain(forName: defaultsName) }
        let clock = RetryTestClock()
        let sender = LabellerSenderStub(outcomes: [
            .fail(.temporary),
            .respond(LabellerResponse(text: mustCutReply(), usage: LabellerUsage())),
            .respond(LabellerResponse(text: mustCutReply(), usage: LabellerUsage())),
        ])
        try await saveFeed(in: fixture.store)
        // Calls: 0 transcript (wait), 1 cut on the reused cues (mismatch), 2 transcript, 3 cut.
        let worker = retryWorker(try writeCueFile(to: fixture.workDirectory), fixture: fixture, cutMismatchOnCall: 1)
        let pipeline = retryPipeline(
            fixture, runner: worker, labelling: configureLabelling(defaults: defaults, sender: sender), clock: clock)
        _ = try await prepareExpectingWait(pipeline, fixture, attempt: try await startTicket(fixture, clock: clock))
        clock.advance(120)
        let result = try await pipeline.prepare(
            episodeID: fixture.episodeID, attempt: try await startTicket(fixture, clock: clock))
        #expect(result.adRemovalOutcome == "cut")
        #expect(try await stageCounts(worker) == (2, 2, 0))
        #expect(sender.requestCount == 3)
        #expect(!FileManager.default.fileExists(atPath: cueFileURL(fixture).path))
    }

    @Test func aRunStartingDeletesOtherRequestsCueFilesForTheSameEpisodeOnly() async throws {
        let fixture = try await Fixture()
        let (defaults, defaultsName) = makeDefaults()
        defer { fixture.remove(); defaults.removePersistentDomain(forName: defaultsName) }
        let clock = RetryTestClock()
        let sender = LabellerSenderStub(outcomes: [
            .respond(LabellerResponse(text: mustCutReply(), usage: LabellerUsage()))
        ])
        try await saveFeed(in: fixture.store)
        let directory = cueFileURL(fixture).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let older = cueFileURL(fixture, sequence: 4)
        let otherEpisode = directory.appendingPathComponent("item-other.4.json")
        try Data("{}".utf8).write(to: older)
        try Data("{}".utf8).write(to: otherEpisode)
        let worker = retryWorker(try writeCueFile(to: fixture.workDirectory), fixture: fixture)
        _ = try await retryPipeline(
            fixture, runner: worker, labelling: configureLabelling(defaults: defaults, sender: sender), clock: clock)
            .prepare(episodeID: fixture.episodeID, attempt: try await startTicket(fixture, clock: clock))
        #expect(!FileManager.default.fileExists(atPath: older.path))
        #expect(FileManager.default.fileExists(atPath: otherEpisode.path))
    }

    // MARK: Stopping

    @Test func aFailureThatCannotImproveStopsWithoutDeferringAndDeletesTheFile() async throws {
        let fixture = try await Fixture()
        let (defaults, defaultsName) = makeDefaults()
        defer { fixture.remove(); defaults.removePersistentDomain(forName: defaultsName) }
        let clock = RetryTestClock()
        let sender = LabellerSenderStub(outcomes: [.fail(.temporary), .fail(.modelUnavailable)])
        try await saveFeed(in: fixture.store)
        let worker = retryWorker(try writeCueFile(to: fixture.workDirectory), fixture: fixture)
        let pipeline = retryPipeline(
            fixture, runner: worker, labelling: configureLabelling(defaults: defaults, sender: sender), clock: clock)
        _ = try await prepareExpectingWait(pipeline, fixture, attempt: try await startTicket(fixture, clock: clock))
        #expect(FileManager.default.fileExists(atPath: cueFileURL(fixture).path))
        clock.advance(120)
        let status = StatusLog()
        let result = try await pipeline.prepare(
            episodeID: fixture.episodeID, attempt: try await startTicket(fixture, clock: clock),
            onStatus: { status.append($0.stage, detail: $0.detail) })
        #expect(result.adRemovalOutcome == "uncertain")
        #expect(result.warning == "original audio includes ads: The labelling model is unavailable.")
        #expect(status.stages.contains("ads.label.stop"))
        #expect(try await ticket(fixture).state == .running, "a stop never defers")
        #expect(try await ticket(fixture).deferralCount == 1, "only the first failure deferred")
        #expect(!FileManager.default.fileExists(atPath: cueFileURL(fixture).path))
        let entries = try await fixture.store.preparationJournal(
            for: PodcastPreparationPipeline.requestID(for: fixture.episodeID))
        let stop = try #require(entries.compactMap(\.status.evidence).first { $0.kind == "labeller-stop" })
        #expect(stop.fields["kind"] == "model-unavailable")
    }

    @Test func aWaitKindPastTheWaitLimitStopsMeasuredFromTheFirstDeferral() async throws {
        let fixture = try await Fixture()
        let (defaults, defaultsName) = makeDefaults()
        defer { fixture.remove(); defaults.removePersistentDomain(forName: defaultsName) }
        let clock = RetryTestClock()
        let sender = LabellerSenderStub(outcomes: [.fail(.temporary), .fail(.temporary)])
        try await saveFeed(in: fixture.store)
        let worker = retryWorker(try writeCueFile(to: fixture.workDirectory), fixture: fixture)
        let labelling = configureLabelling(defaults: defaults, sender: sender)
        let pipeline = retryPipeline(fixture, runner: worker, labelling: labelling, clock: clock)
        _ = try await prepareExpectingWait(pipeline, fixture, attempt: try await startTicket(fixture, clock: clock))
        // 118 minutes after the first deferral, the next back-off (5 minutes) passes two hours.
        clock.advance(118 * 60)
        let result = try await pipeline.prepare(
            episodeID: fixture.episodeID, attempt: try await startTicket(fixture, clock: clock))
        #expect(result.adRemovalOutcome == "uncertain")
        #expect(result.warning == "original audio includes ads: The provider did not answer in time.")
        #expect(try await ticket(fixture).deferralCount == 1)
        #expect(labelling.preferences.providerPauseCount == 1)
    }

    @Test func aFirstFailureWithAShortWaitLimitStopsAtOnce() async throws {
        let fixture = try await Fixture()
        let (defaults, defaultsName) = makeDefaults()
        defer { fixture.remove(); defaults.removePersistentDomain(forName: defaultsName) }
        let clock = RetryTestClock()
        let sender = LabellerSenderStub(outcomes: [.fail(.usageLimit)])
        try await saveFeed(in: fixture.store)
        let labelling = configureLabelling(defaults: defaults, sender: sender)
        labelling.preferences.waitLimit = 60
        let worker = retryWorker(try writeCueFile(to: fixture.workDirectory), fixture: fixture)
        let result = try await retryPipeline(fixture, runner: worker, labelling: labelling, clock: clock)
            .prepare(episodeID: fixture.episodeID, attempt: try await startTicket(fixture, clock: clock))
        #expect(result.adRemovalOutcome == "uncertain")
        #expect(result.warning?.hasSuffix("The provider did not answer in time.") == true)
        #expect(try await ticket(fixture).deferralCount == nil)
        #expect(labelling.preferences.providerPauseCount == 0, "only temporary failures count toward a pause")
    }

    // MARK: Daily cap

    @Test func atTheDailyCapNothingIsSentAndTheTicketWaitsForLocalMidnight() async throws {
        let fixture = try await Fixture()
        let (defaults, defaultsName) = makeDefaults()
        defer { fixture.remove(); defaults.removePersistentDomain(forName: defaultsName) }
        let calendar = Calendar.current
        let night = try #require(calendar.date(from: DateComponents(
            year: 2023, month: 11, day: 14, hour: 23, minute: 0)))
        let midnight = try #require(calendar.nextDate(
            after: night, matching: DateComponents(hour: 0, minute: 0, second: 0), matchingPolicy: .nextTime))
        let clock = RetryTestClock(night)
        let sender = LabellerSenderStub(outcomes: [.respond(LabellerResponse(text: mustCutReply(), usage: LabellerUsage()))])
        try await saveFeed(in: fixture.store)
        let labelling = configureLabelling(defaults: defaults, sender: sender)
        labelling.preferences.dailyCap = 0
        let worker = retryWorker(try writeCueFile(to: fixture.workDirectory), fixture: fixture)
        let error = try await prepareExpectingWait(
            retryPipeline(fixture, runner: worker, labelling: labelling, clock: clock), fixture,
            attempt: try await startTicket(fixture, clock: clock))
        #expect(error == .labellerWaiting(until: midnight, kind: "daily-cap"))
        let deferred = try await ticket(fixture)
        #expect(deferred.state == .deferred)
        #expect(deferred.nextEligibleAt == Timestamp(midnight))
        #expect(deferred.failureKind == WorkTicketDeferralReason.dailyRequestCap.rawValue)
        #expect(sender.requestCount == 0)
        #expect(try await stageCounts(worker) == (0, 0, 0))
    }

    @Test func atTheDailyCapWithMidnightPastTheWaitLimitTheOriginalIsPublishedWithTheCapReason() async throws {
        let fixture = try await Fixture()
        let (defaults, defaultsName) = makeDefaults()
        defer { fixture.remove(); defaults.removePersistentDomain(forName: defaultsName) }
        let noon = try #require(Calendar.current.date(from: DateComponents(
            year: 2023, month: 11, day: 14, hour: 12, minute: 0)))
        let clock = RetryTestClock(noon)
        let sender = LabellerSenderStub(outcomes: [.respond(LabellerResponse(text: mustCutReply(), usage: LabellerUsage()))])
        try await saveFeed(in: fixture.store)
        let labelling = configureLabelling(defaults: defaults, sender: sender)
        labelling.preferences.dailyCap = 0
        let worker = retryWorker(try writeCueFile(to: fixture.workDirectory), fixture: fixture)
        let result = try await retryPipeline(fixture, runner: worker, labelling: labelling, clock: clock)
            .prepare(episodeID: fixture.episodeID, attempt: try await startTicket(fixture, clock: clock))
        #expect(result.adRemovalOutcome == "uncertain")
        #expect(result.warning == "original audio includes ads: The daily limit for online labelling was reached.")
        #expect(sender.requestCount == 0)
        #expect(try await stageCounts(worker) == (0, 0, 1))
        #expect(try await ticket(fixture).deferralCount == nil)
    }

    // MARK: Prepare Again and runs without a generation

    @Test func prepareAgainNeverDefersAndKeepsTheExistingCut() async throws {
        let fixture = try await Fixture()
        let (defaults, defaultsName) = makeDefaults()
        defer { fixture.remove(); defaults.removePersistentDomain(forName: defaultsName) }
        let clock = RetryTestClock()
        let sender = LabellerSenderStub(outcomes: [.fail(.rateLimited(retryAfter: 30))])
        try await saveFeed(in: fixture.store)
        _ = try await fixture.pipeline(Fixture.cuttingStub(), engineVersion: "podcast-preparation-v15")
            .prepare(episodeID: fixture.episodeID)
        let candidate = try #require(try await fixture.store.podcastEpisodesToPrepareAgain().first)
        let staged = try fixture.staged(Fixture.originalBody)
        let attempt = try await startTicket(fixture, clock: clock)
        let ticketBefore = try await ticket(fixture)
        let worker = retryWorker(try writeCueFile(to: fixture.workDirectory), fixture: fixture)
        let outcome = try await retryPipeline(
            fixture, runner: worker, labelling: configureLabelling(defaults: defaults, sender: sender), clock: clock)
            .prepareAgain(candidate: candidate, stage: { staged }, attempt: attempt)
        guard case .keptExisting = outcome else { Issue.record("expected the cut to be kept, got \(outcome)"); return }
        #expect(try await ticket(fixture) == ticketBefore, "the ticket is untouched")
        #expect(!FileManager.default.fileExists(atPath: cueFileURL(fixture).path))
        #expect(try await stageCounts(worker) == (1, 0, 1))
    }

    @Test func aRunWithoutAGenerationNeverDefers() async throws {
        let fixture = try await Fixture()
        let (defaults, defaultsName) = makeDefaults()
        defer { fixture.remove(); defaults.removePersistentDomain(forName: defaultsName) }
        let clock = RetryTestClock()
        let sender = LabellerSenderStub(outcomes: [.fail(.temporary)])
        try await saveFeed(in: fixture.store)
        let labelling = configureLabelling(defaults: defaults, sender: sender)
        let worker = retryWorker(try writeCueFile(to: fixture.workDirectory), fixture: fixture)
        let result = try await retryPipeline(fixture, runner: worker, labelling: labelling, clock: clock)
            .prepare(episodeID: fixture.episodeID)
        #expect(result.adRemovalOutcome == "uncertain")
        #expect(result.warning == "original audio includes ads: The provider did not answer in time.")
        #expect(labelling.preferences.providerPauseCount == 0, "no ticket, so nothing counts toward a pause")
        #expect(!FileManager.default.fileExists(atPath: fixture.workDirectory
            .appendingPathComponent("labeller-cues").path))
    }

    @Test func aRunWithoutAGenerationAtTheDailyCapStopsWithTheCapReason() async throws {
        let fixture = try await Fixture()
        let (defaults, defaultsName) = makeDefaults()
        defer { fixture.remove(); defaults.removePersistentDomain(forName: defaultsName) }
        // An hour before midnight a ticketed run would wait; this one has nothing to park.
        let night = try #require(Calendar.current.date(from: DateComponents(
            year: 2023, month: 11, day: 14, hour: 23, minute: 0)))
        let clock = RetryTestClock(night)
        let sender = LabellerSenderStub(outcomes: [])
        try await saveFeed(in: fixture.store)
        let labelling = configureLabelling(defaults: defaults, sender: sender)
        labelling.preferences.dailyCap = 0
        let worker = retryWorker(try writeCueFile(to: fixture.workDirectory), fixture: fixture)
        let result = try await retryPipeline(fixture, runner: worker, labelling: labelling, clock: clock)
            .prepare(episodeID: fixture.episodeID)
        #expect(result.adRemovalOutcome == "uncertain")
        #expect(result.warning == "original audio includes ads: The daily limit for online labelling was reached.")
        #expect(sender.requestCount == 0)
    }

    // MARK: Provider pause

    @Test func theThirdWaitLimitStopPausesTheProviderAndASuccessClearsIt() async throws {
        let (defaults, defaultsName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let clock = RetryTestClock()
        func episode(_ outcomes: [LabellerSenderStub.Outcome]) async throws
            -> (PodcastPreparationResult, LabellerSenderStub, AdLabellerPreferences) {
            let fixture = try await Fixture()
            defer { fixture.remove() }
            let sender = LabellerSenderStub(outcomes: outcomes)
            try await saveFeed(in: fixture.store)
            let labelling = configureLabelling(defaults: defaults, sender: sender)
            labelling.preferences.waitLimit = 60
            let worker = retryWorker(try writeCueFile(to: fixture.workDirectory), fixture: fixture)
            let result = try await retryPipeline(fixture, runner: worker, labelling: labelling, clock: clock)
                .prepare(episodeID: fixture.episodeID, attempt: try await startTicket(fixture, clock: clock))
            return (result, sender, labelling.preferences)
        }
        for expected in 1...2 {
            let (result, _, preferences) = try await episode([.fail(.temporary)])
            #expect(result.warning?.hasSuffix("The provider did not answer in time.") == true)
            #expect(preferences.providerPauseCount == expected)
            #expect(preferences.providerPausedSince == nil)
        }
        let (third, _, preferences) = try await episode([.fail(.temporary)])
        #expect(third.adRemovalOutcome == "uncertain")
        #expect(preferences.providerPauseCount == 3)
        #expect(preferences.providerPausedSince == clock.now)

        // Paused: the episode still makes its one request, and stops at once without a wait.
        clock.advance(600)
        let (paused, pausedSender, _) = try await episode([.fail(.temporary)])
        #expect(pausedSender.requestCount == 1)
        #expect(paused.warning?.contains("The provider has not answered since") == true)
        #expect(paused.warning?.hasSuffix("Check the model name in Settings.") == true)
        #expect(preferences.providerPauseCount == 3, "a paused stop adds nothing")

        let (cut, _, after) = try await episode([
            .respond(LabellerResponse(text: mustCutReply(), usage: LabellerUsage()))])
        #expect(cut.adRemovalOutcome == "cut")
        #expect(after.providerPauseCount == 0)
        #expect(after.providerPausedSince == nil)
    }

    // MARK: Remote by default

    @Test func theLabelledPathRunsWhenShadowIsUnsetAndNotWhenItIsStoredTrue() async throws {
        for shadow in [nil, true] as [Bool?] {
            let fixture = try await Fixture()
            let (defaults, defaultsName) = makeDefaults()
            defer { fixture.remove(); defaults.removePersistentDomain(forName: defaultsName) }
            let sender = LabellerSenderStub(outcomes: [
                .respond(LabellerResponse(text: mustCutReply(), usage: LabellerUsage()))])
            try await saveFeed(in: fixture.store)
            let labelling = configureLabelling(defaults: defaults, sender: sender, shadow: shadow)
            #expect((defaults.object(forKey: AdLabellerPreferences.keyPrefix + "shadow") != nil) == (shadow != nil))
            let worker = retryWorker(try writeCueFile(to: fixture.workDirectory), fixture: fixture)
            _ = try await retryPipeline(fixture, runner: worker, labelling: labelling, clock: RetryTestClock())
                .prepare(episodeID: fixture.episodeID)
            let stages = try await worker.allRequests().map { try decodeRequest($0)["adStage"] as? String }
            #expect(stages == (shadow == nil ? ["transcript", "cut"] : [nil]))
            #expect(sender.requestCount == (shadow == nil ? 1 : 0))
        }
    }
}
