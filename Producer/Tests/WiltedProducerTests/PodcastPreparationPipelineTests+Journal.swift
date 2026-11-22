import Foundation
import Testing
import WiltedDomain
@testable import WiltedProducer

private final class AdvancingTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Double

    init(start: Double = 1_700_000_200.0) {
        self.current = start
    }

    func nextDate() -> Date {
        lock.lock(); defer { lock.unlock() }
        current += 1.0
        return Date(timeIntervalSince1970: current)
    }
}

extension PodcastPreparationPipelineTests {
    // MARK: Error descriptions carry bounded single-line detail

    @Test func errorDescriptionsCarryBoundedSingleLineDetail() throws {
        // workerUnavailable with normal detail
        let unavailable = PodcastPreparationError.workerUnavailable("no Wilted runtime source at /path/to/runtime")
        #expect(unavailable.errorDescription == "Wilted could not start the preparation pipeline: no Wilted runtime source at /path/to/runtime.")

        // workerUnavailable with empty detail keeps the old sentence
        let unavailableEmpty = PodcastPreparationError.workerUnavailable("")
        #expect(unavailableEmpty.errorDescription == "Wilted could not start the preparation pipeline.")

        // malformedWorkerResponse with normal detail
        let malformed = PodcastPreparationError.malformedWorkerResponse("unsupported protocolVersion")
        #expect(malformed.errorDescription == "The preparation pipeline returned an unreadable result: unsupported protocolVersion.")

        // malformedWorkerResponse with empty detail keeps the old sentence
        let malformedEmpty = PodcastPreparationError.malformedWorkerResponse("")
        #expect(malformedEmpty.errorDescription == "The preparation pipeline returned an unreadable result.")

        // multiline detail is collapsed to a single line
        let multiline = PodcastPreparationError.workerUnavailable("first line\n  second line\r\nthird line")
        #expect(multiline.errorDescription == "Wilted could not start the preparation pipeline: first line second line third line.")

        // 1000-char detail is capped to 300 characters with ellipsis
        let longDetail = String(repeating: "a", count: 1000)
        let cappedUnavailable = PodcastPreparationError.workerUnavailable(longDetail)
        let unavailableDescription = try #require(cappedUnavailable.errorDescription)
        let expectedCappedUnavailable = String(repeating: "a", count: 299) + "…"
        #expect(unavailableDescription == "Wilted could not start the preparation pipeline: \(expectedCappedUnavailable).")
        #expect(expectedCappedUnavailable.count == 300)

        let cappedMalformed = PodcastPreparationError.malformedWorkerResponse(longDetail)
        let malformedDescription = try #require(cappedMalformed.errorDescription)
        let expectedCappedMalformed = String(repeating: "a", count: 299) + "…"
        #expect(malformedDescription == "The preparation pipeline returned an unreadable result: \(expectedCappedMalformed).")
        #expect(expectedCappedMalformed.count == 300)
    }

    // MARK: Heartbeat stages deduplication

    @Test func heartbeatStagesDeduplicateInJournalWhileAllProgressEmitted() async throws {
        let fixture = try await Fixture(labelled: true)
        defer { fixture.remove() }

        var progressItems: [PodcastPreparationProgress] = []
        for i in 1...50 {
            progressItems.append(PodcastPreparationProgress(stage: "ads.model.wait", detail: "waiting lock \(i)"))
        }
        progressItems.append(PodcastPreparationProgress(stage: "stage.distinct.alpha", detail: "alpha detail"))
        progressItems.append(PodcastPreparationProgress(stage: "stage.distinct.beta", detail: "beta detail"))

        let runner = WorkerStub(
            response: [
                "ok": true, "timing": "none", "audioPath": fixture.audioURL.path, "audioChanged": false,
            ],
            progress: progressItems
        )

        let statusLog = StatusLog()
        let clock = AdvancingTestClock()

        _ = try await fixture.pipeline(runner, now: { clock.nextDate() }).prepare(
            episodeID: fixture.episodeID,
            onStatus: { progress in
                statusLog.append(progress.stage, detail: progress.detail)
            }
        )

        // onStatus saw all 52 worker progress events, beside the pipeline's own stages
        let workerStages = statusLog.stages.filter { $0 == "ads.model.wait" || $0.hasPrefix("stage.distinct.") }
        #expect(workerStages.count == 52)
        #expect(statusLog.stages.filter { $0 == "ads.model.wait" }.count == 50)
        #expect(statusLog.stages.contains("stage.distinct.alpha"))
        #expect(statusLog.stages.contains("stage.distinct.beta"))

        let entries = try await fixture.store.preparationJournal(
            for: PodcastPreparationPipeline.requestID(for: fixture.episodeID)
        )

        // Exactly one journal row for "ads.model.wait" holding the last detail
        let waitEntries = entries.filter { $0.status.step == "ads.model.wait" }
        #expect(waitEntries.count == 1)
        #expect(waitEntries.first?.status.detail == "waiting lock 50")

        // Distinct rows for the other two stages
        let alphaEntries = entries.filter { $0.status.step == "stage.distinct.alpha" }
        #expect(alphaEntries.count == 1)
        #expect(alphaEntries.first?.status.detail == "alpha detail")

        let betaEntries = entries.filter { $0.status.step == "stage.distinct.beta" }
        #expect(betaEntries.count == 1)
        #expect(betaEntries.first?.status.detail == "beta detail")
    }

    // MARK: Out-of-order / stale journal writes

    @Test func staleJournalWriteNeverReplacesNewerRow() async throws {
        let root = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalLibraryStore(url: root.appendingPathComponent("library.sqlite"))

        let itemID = PodcastPreparationPipelineTests.itemID
        let requestID = "test-request"
        let entryID = "test-entry-heartbeat"

        let newerTime = Timestamp(Date(timeIntervalSince1970: 1_700_000_500))
        let olderTime = Timestamp(Date(timeIntervalSince1970: 1_700_000_100))

        let newerStatus = try PreparationStatus(
            stage: .preparing, detail: "newer detail", cancellable: true, emittedAt: newerTime, step: "ads.model.wait"
        )
        let newerEntry = PreparationJournalEntry(
            id: entryID, itemID: itemID, requestID: requestID, status: newerStatus
        )

        let olderStatus = try PreparationStatus(
            stage: .preparing, detail: "older detail", cancellable: true, emittedAt: olderTime, step: "ads.model.wait"
        )
        let olderEntry = PreparationJournalEntry(
            id: entryID, itemID: itemID, requestID: requestID, status: olderStatus
        )

        // Record the newer entry first
        try await store.record(preparation: newerEntry)

        // Record the older entry second (simulating out-of-order task completion)
        try await store.record(preparation: olderEntry)

        let entries = try await store.preparationJournal(for: requestID)
        #expect(entries.count == 1)
        #expect(entries.first?.id == entryID)
        #expect(entries.first?.status.detail == "newer detail")
        #expect(entries.first?.status.emittedAt == newerTime)
    }

    // MARK: A show that is not sent keeps its ads and says why

    /// One way a show with ad removal on is not sent for ad finding. Each
    /// labelled fixture would go online but for this one reason.
    enum NotSentShow: String, CaseIterable, Sendable {
        case switchOff, noLabellingServices, noKey, notConfirmed, macOnly

        var reason: RemoteLabellingNotSent {
            switch self {
            case .switchOff, .noLabellingServices: .switchOff
            case .noKey: .noKey
            case .notConfirmed, .macOnly: .notConfirmed
            }
        }

        func fixture() async throws -> Fixture {
            switch self {
            case .noLabellingServices: return try await Fixture()
            case .switchOff, .noKey, .notConfirmed, .macOnly: break
            }
            let fixture = try await Fixture(labelled: true)
            do {
                let services = try #require(fixture.labelling)
                let feedID = try #require(try await fixture.store.podcastEpisode(for: fixture.episodeID)).feedID
                switch self {
                case .switchOff: services.preferences.isEnabled = false
                case .noKey: try services.keyStore.remove()
                case .notConfirmed: services.preferences.setConfirmed(feedID: feedID.rawValue, false)
                case .macOnly:
                    services.preferences.preferences.set(
                        [feedID.rawValue], forKey: AdLabellerPreferences.keyPrefix + "localOnlyFeedIDs")
                default: break
                }
            } catch {
                fixture.remove()
                throw error
            }
            return fixture
        }
    }

    /// A worker that runs no ad finder: the only answer a not-sent show may get.
    private static func plainWorker(_ fixture: Fixture) -> WorkerStub {
        WorkerStub(response: ["ok": true, "timing": "none", "audioPath": fixture.audioURL.path, "audioChanged": false])
    }

    private static func decodedRequests(_ worker: WorkerStub) async throws -> [[String: Any]] {
        try await worker.allRequests().map { try #require(try JSONSerialization.jsonObject(with: $0) as? [String: Any]) }
    }

    @Test(arguments: NotSentShow.allCases)
    func aShowThatIsNotSentKeepsItsAdsAndSaysWhy(show: NotSentShow) async throws {
        let fixture = try await show.fixture()
        defer { fixture.remove() }
        // At the cap a labelled run with a ticket waits for the next day; a not-sent one never does.
        fixture.labelling?.preferences.dailyCap = 0
        let ticket = try await fixture.store.readmitWorkTicket(
            kind: .podcastPreparation, subjectID: fixture.episodeID.rawValue, requestSequence: 1,
            to: .running, at: Timestamp(Date(timeIntervalSince1970: 1_700_000_150)))
        let attempt = try PreparationAttemptIdentity(
            requestSequence: ticket.requestSequence, attemptCount: ticket.attemptCount)
        let worker = Self.plainWorker(fixture)
        let statuses = StatusLog()
        let result = try await fixture.pipeline(worker).prepare(
            episodeID: fixture.episodeID, attempt: attempt,
            onStatus: { statuses.append($0.stage, detail: $0.detail) })
        let reason = show.reason

        let requests = try await Self.decodedRequests(worker)
        #expect(requests.count == 1, "one worker call")
        #expect(requests.allSatisfy { $0["removeAds"] as? Bool == false && $0["adStage"] == nil },
                "no ad finder runs, local or labelled")
        #expect((fixture.sender?.requestCount ?? 0) == 0, "nothing is sent to the provider")
        #expect((fixture.labelling?.counter.count ?? 0) == 0, "no request is counted")
        #expect(result.adRemovalOutcome == "uncertain")
        #expect(result.warning == "original audio includes ads: \(reason.sentence)")
        #expect(result.revision.revisionID == fixture.revisionID)
        #expect(result.mediaURL == fixture.audioURL)
        #expect(try Data(contentsOf: result.mediaURL) == Fixture.originalBody, "the original audio is published")

        let outcome = try #require(try await fixture.store.preparationOutcome(
            for: fixture.episodeID, revisionID: result.revision.revisionID))
        let policy = PodcastPreparationPolicySnapshot(transcriptPolicy: .bestAvailable, removeAds: true)
        #expect(outcome.policyDigest == PodcastPreparationPipeline.policyDigest(policy, labelled: nil),
                "no labelled provenance: the plain digest is recorded")

        let entries = try await fixture.store.preparationJournal(
            for: PodcastPreparationPipeline.requestID(for: fixture.episodeID))
        let notSent = entries.filter { $0.status.step == "ads.not-sent" }
        #expect(notSent.count == 1)
        #expect(notSent.first?.status.evidence?.kind == reason.kind)
        #expect(notSent.first?.status.detail == reason.sentence)
        #expect(statuses.stages.filter { $0 == "ads.not-sent" }.count == 1)
        #expect(!statuses.stages.contains("ads.uncertain"), "the labelled path's stop is not taken")
        #expect(fixture.leftoverLabellerCueFiles().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.workDirectory
            .appendingPathComponent("wilted-pipeline/labeller-cues.json").path), "no cues were exported")
        #expect(try await fixture.store.workTicket(
            kind: .podcastPreparation, subjectID: fixture.episodeID.rawValue)?.state != .deferred)
    }

    /// Ad removal off, or a show marked as having no ads, is the plain path
    /// whatever else would have kept the show from being sent.
    @Test(arguments: [NotSentShow.switchOff, .noKey, .notConfirmed], [false, true])
    func adRemovalOffOrAnAdFreeShowStaysPlain(show: NotSentShow, adFree: Bool) async throws {
        let fixture = try await show.fixture()
        defer { fixture.remove() }
        let services = try #require(fixture.labelling)
        let feedID = try #require(try await fixture.store.podcastEpisode(for: fixture.episodeID)).feedID
        if adFree { services.preferences.preferences.set([feedID.rawValue], forKey: AdLabellerPreferences.adFreeFeedsKey) }
        let policy = PodcastPreparationPolicySnapshot(transcriptPolicy: .bestAvailable, removeAds: adFree)
        let worker = Self.plainWorker(fixture)
        let statuses = StatusLog()
        let result = try await fixture.pipeline(worker).prepare(
            episodeID: fixture.episodeID, policy: policy, onStatus: { statuses.append($0.stage) })

        #expect(result.adRemovalOutcome == "disabled")
        #expect(result.warning == nil)
        #expect(!statuses.stages.contains("ads.not-sent"))
        let entries = try await fixture.store.preparationJournal(
            for: PodcastPreparationPipeline.requestID(for: fixture.episodeID))
        #expect(!entries.contains { $0.status.step == "ads.not-sent" })
        #expect(try await Self.decodedRequests(worker).allSatisfy {
            $0["removeAds"] as? Bool == false && $0["adStage"] == nil })
        #expect(fixture.sender?.requestCount == 0)
    }

}
