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
    static let feedURL = URL(string: "https://feeds.example.test/show.xml")!
    static let feedID = try! ItemID.derivePodcastFeed(from: feedURL)
    static let showTitle = "Invented Garden Show"
    static let key = "invented-key-0123456789abcdef"
    static let engineVersion = "engine-v9"
    static let goodReply =
        #"{"breaks":[{"startSegment":1,"endSegment":2,"kind":"sponsor","label":"must-cut","advertisers":["Fizzbolt"]}]}"#
    static let garbageReply = "I cannot answer in JSON."

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

    /// Regression: the backfill ignored the owner's name for a show.
    @Test func anEpisodeOnAShowTheOwnerNamedAdFreeIsNotSent() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let episodes = [try await addEpisode(fixture, ordinal: 1)]
        try await fixture.store.save(subscription: PodcastSubscription(
            feedID: Self.feedID, subscribedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000)),
            displayName: "Garden Plus"))
        let records = try recordsDirectory("custom-name")
        defer { try? FileManager.default.removeItem(at: records) }
        let sender = StubSender(outcomes: [.respond(LabellerResponse(text: Self.goodReply, usage: LabellerUsage()))])
        let recorder = makeRecorder(fixture: fixture, sender: sender, recordsDirectory: records)
        let summary = await makeBackfill(
            fixture: fixture, recorder: recorder, worker: CuesExportWorker(script: .export, exports: episodes)).run()
        #expect(summary == LabellerBackfill.Summary(recorded: 0, failed: 0, remaining: 0, ending: .nothingToLabel))
        #expect(sender.requestCount == 0)
    }

    @Test func anEpisodeOnAnAdFreeFeedIsNotSent() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let episodes = [try await addEpisode(fixture, ordinal: 1)]
        fixture.defaults.set([Self.feedID.rawValue], forKey: AdLabellerPreferences.adFreeFeedsKey)
        let records = try recordsDirectory("ad-free-feed")
        defer { try? FileManager.default.removeItem(at: records) }
        let sender = StubSender(outcomes: [.respond(LabellerResponse(text: Self.goodReply, usage: LabellerUsage()))])
        let recorder = makeRecorder(fixture: fixture, sender: sender, recordsDirectory: records)
        let summary = await makeBackfill(
            fixture: fixture, recorder: recorder, worker: CuesExportWorker(script: .export, exports: episodes)).run()
        #expect(summary == LabellerBackfill.Summary(recorded: 0, failed: 0, remaining: 0, ending: .nothingToLabel))
        #expect(sender.requestCount == 0)
    }

    @Test func anEpisodePreparedWithAdRemovalDisabledIsNotSent() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let episodes = [try await addEpisode(fixture, ordinal: 1, outcome: "disabled")]
        let records = try recordsDirectory("ad-removal-disabled")
        defer { try? FileManager.default.removeItem(at: records) }
        let sender = StubSender(outcomes: [.respond(LabellerResponse(text: Self.goodReply, usage: LabellerUsage()))])
        let recorder = makeRecorder(fixture: fixture, sender: sender, recordsDirectory: records)
        let summary = await makeBackfill(
            fixture: fixture, recorder: recorder, worker: CuesExportWorker(script: .export, exports: episodes)).run()
        #expect(summary == LabellerBackfill.Summary(recorded: 0, failed: 0, remaining: 0, ending: .nothingToLabel))
        #expect(sender.requestCount == 0)
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
