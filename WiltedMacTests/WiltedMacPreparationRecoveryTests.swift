import Foundation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

@MainActor
final class WiltedMacPreparationRecoveryTests: XCTestCase {
    private struct Job: Sendable {
        let name: String
        let sequence: Int
        var state: WorkTicketState = .pending
        var kept = true
        var prepared = false
        var removed = false
        var downloaded = true
        var snapshot: Data? = try! JSONEncoder().encode(PodcastPreparationPolicySnapshot(
            transcriptPolicy: .noLocalSTT, removeAds: false))
        var processing: Data?
        var nextEligible: Timestamp?
    }

    private func fixture(_ jobs: [Job], holdGate: Bool = true, runner: RecoverySleepingRunner = RecoverySleepingRunner(), forcedRedownload: Set<String> = []) async throws -> (WiltedMacModel, LocalLibraryStore, [String: String]) {
        let directory = wiltedTemporaryDirectory("pending-preparation-launch")
        let feedURL = URL(string: "https://example.test/pending-preparation-launch.xml")!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        var ids: [String: String] = [:]
        for job in jobs {
            ids[job.name] = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: job.name,
                enclosureURL: URL(string: "https://example.test/\(job.name).mp3")!).rawValue
        }
        let jobIDs = ids
        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: PodcastFeed(itemID: feedID, canonicalURL: feedURL,
                    title: "Recovery", createdAt: created))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                for job in jobs {
                    let id = try ItemID(rawValue: jobIDs[job.name]!)
                    let enclosure = URL(string: "https://example.test/\(job.name).mp3")!
                    if job.prepared {
                        try await WiltedMacModelTests.addReadyEpisode(id, guid: job.name, feedID: feedID,
                            feedURL: feedURL, enclosureURL: enclosure, publishedAt: created.date,
                            directory: directory, store: store, created: created)
                    } else if job.downloaded {
                        try await WiltedMacModelTests.addDownloadedUnpreparedEpisode(id, guid: job.name,
                            feedID: feedID, feedURL: feedURL, enclosureURL: enclosure, publishedAt: created.date,
                            directory: directory, store: store, created: created)
                    } else {
                        try await store.save(episode: PodcastEpisode(itemID: id, feedID: feedID,
                            feedURL: feedURL, rssGUID: job.name, title: job.name, publishedTime: created,
                            enclosureURL: enclosure, enclosureMediaType: "audio/mpeg", createdAt: created))
                    }
                    if job.kept { try await store.addPodcastQueueEpisode(id) }
                    if job.removed { _ = try await store.retireEpisode(id) }
                    try await store.upsertWorkTicket(WorkTicket(kind: .podcastPreparation,
                        subjectID: id.rawValue, requestSequence: job.sequence, state: job.state,
                        nextEligibleAt: job.nextEligible, policySnapshot: job.snapshot,
                        processingPolicy: job.processing, requestedAt: created, updatedAt: created))
                }
                return store
            }, podcastDownloadTransportFactory: {
                FailingPodcastDownloadTransport(enclosureURL: URL(string: "https://example.test/forced.mp3")!, statusCode: 404)
            }, podcastPipelineRunnerFactory: { runner },
            pipelineFingerprintResolution: { forcedRedownload.isEmpty ? nil : "recovery-test-fingerprint" },
            staleInvalidationOverride: { _, _ in
                PodcastPreparationInvalidationResult(forcedRedownloadEpisodeIDs: try forcedRedownload.map {
                    try ItemID(rawValue: jobIDs[$0]!)
                })
            }, preferences: WiltedMacTestPreferences.ephemeral())
        addTeardownBlock { await model.close() }
        model.setAutomationSettings(WiltedAutomationSettings(refreshPolicy: .manual,
            downloadPolicy: .manual, processingPolicy: .manual, transcriptPolicy: .alwaysTranscribe, removeAds: true))
        if holdGate { try await model.preparationGateForTesting.admit(sequence: 0) }
        if !forcedRedownload.isEmpty {
            // Isolate the bootstrap exclusion wiring: leave the old source
            // downloaded, but prevent the independent redownload task starting.
            model.startupStepObserverForTesting = { [weak model] step in
                if step == .restoringPlayback { model?.bootstrapRecoveryTask?.cancel() }
            }
        }
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        XCTAssertEqual(model.startupState, .ready)
        let configuredStore = try XCTUnwrap(model.store)
        let durableQueue = try await configuredStore.podcastQueueState()
        XCTAssertEqual(Set(model.podcastQueueIDs), Set(durableQueue.episodeIDs.map(\.rawValue)),
            "Bootstrap must restore the durable raw Keep queue before recovery")
        for job in jobs {
            let id = try XCTUnwrap(ids[job.name])
            _ = try XCTUnwrap(model.episodes.first(where: { $0.id == id }),
                "The subscribed fixture episode must be projected before recovery is assessed: \(job.name)")
            if job.kept && !job.removed {
                XCTAssertTrue(model.podcastQueueIDs.contains(id), "The fixture must retain Keep authority: \(job.name)")
            } else if !job.kept {
                XCTAssertFalse(model.podcastQueueIDs.contains(id), "The negative fixture must have no Keep authority")
            }
        }
        return (model, configuredStore, ids)
    }

    func testBootstrapResumesAdmittedRequestsInSavedOrderAndDoesNotDuplicateThem() async throws {
        let (model, store, ids) = try await fixture([
            Job(name: "late", sequence: 30), Job(name: "early", sequence: 10), Job(name: "middle", sequence: 20)])
        let expected = [ids["early"]!, ids["middle"]!, ids["late"]!]
        XCTAssertEqual(model.preparationQueue.entries.map(\.id), expected)
        XCTAssertEqual(Set(model.podcastPreparationTasks.keys), Set(expected))
        await model.restorePendingPodcastPreparations(in: store)
        XCTAssertEqual(model.preparationQueue.entries.map(\.id), expected)
        let tickets = try await store.workTickets().filter { $0.kind == .podcastPreparation }
        XCTAssertEqual(tickets.count, 3)
        XCTAssertEqual(Set(tickets.map(\.requestSequence)), [10, 20, 30])
        for ticket in tickets {
            let saved = try JSONDecoder().decode(PodcastPreparationPolicySnapshot.self, from: XCTUnwrap(ticket.policySnapshot))
            XCTAssertFalse(saved.removeAds, "Recovery retains admitted policy despite current Settings")
        }
    }

    func testRecoveredRequestReachesTheWorkerThroughTheExistingCoordinator() async throws {
        let runner = RecoverySleepingRunner()
        let (model, store, ids) = try await fixture([Job(name: "runnable", sequence: 9)], holdGate: false, runner: runner)
        var starts = await runner.starts
        for _ in 0..<100 where starts == 0 {
            try await Task.sleep(for: .milliseconds(20))
            starts = await runner.starts
        }
        XCTAssertEqual(starts, 1)
        let ticket = try await store.workTicket(kind: .podcastPreparation, subjectID: ids["runnable"]!)
        XCTAssertEqual(ticket?.requestSequence, 9)
        XCTAssertEqual(ticket?.state, .running)
        await model.restorePendingPodcastPreparations(in: store)
        let repeated = await runner.starts
        XCTAssertEqual(repeated, 1)
    }

    func testBootstrapDoesNotRetryTerminalOrIneligibleEpisodes() async throws {
        let jobs = [Job(name: "failed", sequence: 1, state: .failed),
            Job(name: "cancelled", sequence: 2, state: .cancelled),
            Job(name: "succeeded", sequence: 3, state: .succeeded),
            Job(name: "unkept", sequence: 4, kept: false),
            Job(name: "removed", sequence: 5, removed: true),
            Job(name: "prepared", sequence: 6, prepared: true),
            Job(name: "not-downloaded", sequence: 7, downloaded: false),
            Job(name: "future", sequence: 8,
                nextEligible: Timestamp(Calendar.current.date(byAdding: .day, value: 1, to: Date())!))]
        let (model, _, ids) = try await fixture(jobs)
        XCTAssertTrue(model.podcastPreparationTasks.isEmpty)
        XCTAssertEqual(model.preparationQueue.entries.map(\.id), [ids["future"]!],
            "An admitted future job stays projected for the existing ticker")
        XCTAssertFalse(model.isDeferredForOffPeak(ids["future"]!), "A deadline is not an off-peak window")
    }

    func testUnadmittedDownloadReservationStillObeysManualProcessing() async throws {
        let (model, store, ids) = try await fixture([Job(name: "unadmitted", sequence: 7, snapshot: nil)])
        XCTAssertTrue(model.podcastPreparationTasks.isEmpty)
        XCTAssertEqual(model.preparationRequestSequences[ids["unadmitted"]!], 7)
        let ticket = try await store.workTicket(kind: .podcastPreparation, subjectID: ids["unadmitted"]!)
        XCTAssertEqual(ticket?.state, .pending)
        XCTAssertNil(ticket?.policySnapshot)
    }

    func testMalformedSavedPolicyDoesNotChangePolicyOrBlockAnotherRequest() async throws {
        let (model, store, ids) = try await fixture([
            Job(name: "malformed", sequence: 1, snapshot: Data("bad policy".utf8)),
            Job(name: "valid", sequence: 2)])
        XCTAssertEqual(Set(model.podcastPreparationTasks.keys), [ids["valid"]!])
        let malformed = try await store.workTicket(kind: .podcastPreparation, subjectID: ids["malformed"]!)
        XCTAssertEqual(malformed?.policySnapshot, Data("bad policy".utf8))
        XCTAssertEqual(malformed?.state, .pending)
        XCTAssertEqual(model.podcastOperationMessage,
            "Episode valid is queued behind the preparation in flight.",
            "A policy warning cannot replace another request's operation message")
        model.podcastOperationMessage = "Owner operation remains visible."
        await model.restorePendingPodcastPreparations(in: store)
        XCTAssertEqual(model.podcastOperationMessage, "Owner operation remains visible.")
    }

    func testExplicitPrepareCanRunAfterMalformedPolicyRecoveryWithoutAutomaticTerminalMutation() async throws {
        let runner = RecoverySleepingRunner()
        let (model, store, ids) = try await fixture([
            Job(name: "malformed-explicit", sequence: 18, snapshot: Data("bad saved policy".utf8))], runner: runner)
        let id = ids["malformed-explicit"]!
        let before = try await store.workTicket(kind: .podcastPreparation, subjectID: id)
        XCTAssertEqual(before?.state, .pending)
        XCTAssertEqual(before?.attemptCount, 0)
        XCTAssertNil(model.podcastPreparationTasks[id])
        model.prepareEpisode(try XCTUnwrap(model.episodes.first { $0.id == id }))
        model.preparationGateForTesting.release()
        var starts = await runner.starts
        for _ in 0..<100 where starts == 0 {
            try await Task.sleep(for: .milliseconds(20))
            starts = await runner.starts
        }
        XCTAssertEqual(starts, 1, "Explicit Prepare can use its current captured policy without automatic failure mutation")
        let after = try await store.workTicket(kind: .podcastPreparation, subjectID: id)
        XCTAssertEqual(after?.state, .running)
    }

    func testStoredOffPeakWindowAndSnapshotSurviveBootstrap() async throws {
        let hour = Calendar.current.component(.hour, from: Date())
        let window = try XCTUnwrap(WiltedAutomationOffPeakWindow(
            start: WiltedAutomationLocalTime(hour: (hour + 2) % 24, minute: 0)!,
            end: WiltedAutomationLocalTime(hour: (hour + 3) % 24, minute: 0)!))
        let policy = WiltedAutomationProcessingPolicy.offPeak(window)
        let (model, store, ids) = try await fixture([Job(name: "offpeak", sequence: 12,
            state: .deferred, processing: JSONEncoder().encode(policy))])
        let id = ids["offpeak"]!
        XCTAssertNil(model.podcastPreparationTasks[id])
        XCTAssertTrue(model.isDeferredForOffPeak(id))
        XCTAssertEqual(model.deferredAutomaticPreparations.first?.processingPolicy, policy)
        XCTAssertEqual(model.deferredAutomaticPreparations.first?.policySnapshot.removeAds, false)
        XCTAssertEqual(model.preparationRequestSequences[id], 12)
        await model.restorePendingPodcastPreparations(in: store)
        XCTAssertEqual(model.deferredAutomaticPreparations.filter { $0.episodeID == id }.count, 1)
    }

    func testFutureOffPeakDeadlineStaysProjectedAndTickerHonorsDeadlineAndWindow() async throws {
        let now = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2035, month: 1, day: 15, hour: 4, minute: 30)))
        let hour = Calendar.current.component(.hour, from: now)
        // Current hour is eligible; the following hour is outside this window.
        let window = try XCTUnwrap(WiltedAutomationOffPeakWindow(
            start: WiltedAutomationLocalTime(hour: hour, minute: 0)!,
            end: WiltedAutomationLocalTime(hour: (hour + 1) % 24, minute: 0)!))
        let policy = WiltedAutomationProcessingPolicy.offPeak(window)
        let deadline = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 1, to: now))
        let (model, store, ids) = try await fixture([Job(name: "future-offpeak", sequence: 13,
            state: .deferred, processing: JSONEncoder().encode(policy), nextEligible: Timestamp(deadline))])
        let id = ids["future-offpeak"]!
        XCTAssertTrue(model.isDeferredForOffPeak(id))
        XCTAssertEqual(model.preparationQueue.entries.map(\.id), [id])
        XCTAssertEqual(model.deferredAutomaticPreparations.first?.notBefore, deadline)
        XCTAssertEqual(model.deferredAutomaticPreparations.first?.processingPolicy, policy)
        XCTAssertEqual(model.preparationRequestSequences[id], 13)
        model.startEligibleAutomaticPreparations(at: now)
        XCTAssertNil(model.podcastPreparationTasks[id], "An open window cannot bypass the saved deadline")
        let outsideWindow = Calendar.current.date(bySettingHour: (hour + 1) % 24, minute: 30, second: 0,
            of: Calendar.current.date(byAdding: .day, value: 1, to: deadline)!)!
        model.startEligibleAutomaticPreparations(at: outsideWindow)
        XCTAssertNil(model.podcastPreparationTasks[id], "Passing the deadline cannot bypass the original window")
        model.startEligibleAutomaticPreparations(at: Calendar.current.date(byAdding: .day, value: 1, to: deadline)!)
        XCTAssertNotNil(model.podcastPreparationTasks[id])
        XCTAssertFalse(model.isDeferredForOffPeak(id))
        let ticket = try await store.workTicket(kind: .podcastPreparation, subjectID: id)
        XCTAssertEqual(ticket?.requestSequence, 13)
        let storedPolicy = try JSONDecoder().decode(WiltedAutomationProcessingPolicy.self,
            from: XCTUnwrap(ticket?.processingPolicy))
        XCTAssertEqual(storedPolicy, policy)
    }

    func testFutureAdmittedRequestWithoutWindowResumesOnceWithSavedPolicyUnderManualSettings() async throws {
        let now = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2035, month: 1, day: 15, hour: 12)))
        let deadline = try XCTUnwrap(Calendar.current.date(byAdding: .hour, value: 1, to: now))
        let runner = RecoverySleepingRunner()
        let (model, store, ids) = try await fixture([Job(name: "admitted-backoff", sequence: 17,
            nextEligible: Timestamp(deadline))], holdGate: false, runner: runner)
        let id = ids["admitted-backoff"]!
        XCTAssertEqual(model.automationSettings.processingPolicy, .manual)
        XCTAssertEqual(model.preparationQueue.entries.map(\.id), [id])
        XCTAssertFalse(model.isDeferredForOffPeak(id))
        await model.restorePendingPodcastPreparations(in: store, at: now)
        model.startEligibleAutomaticPreparations(at: now)
        XCTAssertNil(model.podcastPreparationTasks[id])
        XCTAssertEqual(model.deferredAutomaticPreparations.first?.processingPolicy, .immediate)
        XCTAssertEqual(model.deferredAutomaticPreparations.first?.notBefore, deadline)
        model.startEligibleAutomaticPreparations(at: deadline)
        model.startEligibleAutomaticPreparations(at: deadline)
        var starts = await runner.starts
        for _ in 0..<100 where starts == 0 {
            try await Task.sleep(for: .milliseconds(20))
            starts = await runner.starts
        }
        XCTAssertEqual(starts, 1)
        XCTAssertTrue(model.deferredAutomaticPreparations.isEmpty)
        let ticket = try await store.workTicket(kind: .podcastPreparation, subjectID: id)
        XCTAssertEqual(ticket?.requestSequence, 17)
        let snapshot = try JSONDecoder().decode(PodcastPreparationPolicySnapshot.self,
            from: XCTUnwrap(ticket?.policySnapshot))
        XCTAssertFalse(snapshot.removeAds)
        XCTAssertEqual(snapshot.transcriptPolicy, .noLocalSTT)
    }

    func testFutureUnadmittedReservationCannotAcquireCurrentImmediatePolicyBeforeDeadline() async throws {
        let now = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2035, month: 1, day: 15, hour: 12)))
        let deadline = try XCTUnwrap(Calendar.current.date(byAdding: .hour, value: 1, to: now))
        let (model, store, ids) = try await fixture([Job(name: "unadmitted-future", sequence: 19,
            snapshot: nil, nextEligible: Timestamp(deadline))])
        model.setAutomationSettings(WiltedAutomationSettings(refreshPolicy: .manual,
            downloadPolicy: .manual, processingPolicy: .immediate, transcriptPolicy: .alwaysTranscribe, removeAds: true))
        await model.restorePendingPodcastPreparations(in: store, at: now)
        XCTAssertTrue(model.podcastPreparationTasks.isEmpty)
        XCTAssertTrue(model.deferredAutomaticPreparations.isEmpty)
        let ticket = try await store.workTicket(kind: .podcastPreparation, subjectID: ids["unadmitted-future"]!)
        XCTAssertEqual(ticket?.state, .pending)
        XCTAssertNil(ticket?.policySnapshot)
    }

    func testMissingSnapshotKeepsTicketPendingAndReportsHowToPrepareAgain() async throws {
        let processing = try JSONEncoder().encode(WiltedAutomationProcessingPolicy.immediate)
        let (model, store, ids) = try await fixture([Job(name: "missing-snapshot", sequence: 14,
            snapshot: nil, processing: processing)])
        XCTAssertTrue(model.podcastPreparationTasks.isEmpty)
        XCTAssertEqual(model.podcastOperationMessage,
            "Some saved preparations could not be restored. Prepare them again from Larder.")
        let ticket = try await store.workTicket(kind: .podcastPreparation, subjectID: ids["missing-snapshot"]!)
        XCTAssertEqual(ticket?.state, .pending)
        XCTAssertEqual(ticket?.attemptCount, 0)
        XCTAssertNil(ticket?.policySnapshot)
        XCTAssertEqual(ticket?.processingPolicy, processing)
    }

    func testBootstrapPassesForcedRedownloadExclusionIntoPreparationRecovery() async throws {
        let (model, store, ids) = try await fixture([Job(name: "bootstrap-forced", sequence: 15)],
            forcedRedownload: ["bootstrap-forced"])
        let id = ids["bootstrap-forced"]!
        XCTAssertNil(model.podcastPreparationTasks[id], "A forced redownload cannot prepare its old source at launch")
        XCTAssertEqual(model.episodes.first(where: { $0.id == id })?.downloadState, .completed,
            "The intact old source stays otherwise eligible, so exclusion must come from bootstrap")
        let ticket = try await store.workTicket(kind: .podcastPreparation, subjectID: id)
        XCTAssertEqual(ticket?.requestSequence, 15)
        XCTAssertEqual(ticket?.attemptCount, 0)
    }

    func testOptimisticallyHiddenAndRetiredAtOnlyEpisodesCannotResume() async throws {
        let (model, store, ids) = try await fixture([
            Job(name: "retired-at-only", sequence: 1, snapshot: nil),
            Job(name: "optimistically-hidden", sequence: 2, snapshot: nil)])
        let retiredID = ids["retired-at-only"]!
        let hiddenID = ids["optimistically-hidden"]!
        let index = try XCTUnwrap(model.episodes.firstIndex { $0.id == retiredID })
        model.episodes[index].retiredAt = Date()
        XCTAssertNil(model.episodes[index].removalKind)
        model.hiddenEpisodeIDs.insert(hiddenID)
        model.setAutomationSettings(WiltedAutomationSettings(refreshPolicy: .manual,
            downloadPolicy: .manual, processingPolicy: .immediate, transcriptPolicy: .bestAvailable, removeAds: true))
        await model.restorePendingPodcastPreparations(in: store)
        XCTAssertNil(model.podcastPreparationTasks[retiredID])
        XCTAssertNil(model.podcastPreparationTasks[hiddenID])
        let tickets = try await store.workTickets().filter { $0.kind == .podcastPreparation }
        XCTAssertTrue(tickets.allSatisfy { $0.state == .pending && $0.policySnapshot == nil })
    }

    func testBothDeferredCancellationPathsPreventDurableRecoveryFromResurrectingTheJob() async throws {
        let deadline = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2035, month: 1, day: 15, hour: 12)))
        let afterDeadline = try XCTUnwrap(Calendar.current.date(byAdding: .hour, value: 1, to: deadline))
        for cancelFromWaitingRow in [false, true] {
            let name = cancelFromWaitingRow ? "cancel-waiting" : "cancel-episode"
            let (model, store, ids) = try await fixture([Job(name: name, sequence: 20, state: .deferred,
                processing: JSONEncoder().encode(WiltedAutomationProcessingPolicy.immediate),
                nextEligible: Timestamp(deadline))])
            let id = ids[name]!
            XCTAssertNotNil(model.deferredAutomaticPreparations.first { $0.episodeID == id })
            if cancelFromWaitingRow {
                model.cancelWaitingPreparation(try XCTUnwrap(model.preparationQueue.entries.first { $0.id == id }))
            } else {
                model.cancelEpisodePreparation(try XCTUnwrap(model.episodes.first { $0.id == id }))
            }
            var ticket = try await store.workTicket(kind: .podcastPreparation, subjectID: id)
            for _ in 0..<100 where ticket?.state != .cancelled {
                try await Task.sleep(for: .milliseconds(20))
                ticket = try await store.workTicket(kind: .podcastPreparation, subjectID: id)
            }
            XCTAssertEqual(ticket?.state, .cancelled, "Explicit cancellation must reach the durable ticket")
            XCTAssertNil(model.preparationRequestSequences[id])
            await model.restorePendingPodcastPreparations(in: store, at: afterDeadline)
            model.startEligibleAutomaticPreparations(at: afterDeadline)
            XCTAssertNil(model.podcastPreparationTasks[id])
            XCTAssertFalse(model.preparationQueue.entries.contains { $0.id == id })
            XCTAssertFalse(model.deferredAutomaticPreparations.contains { $0.episodeID == id })
            let afterRecovery = try await store.workTicket(kind: .podcastPreparation, subjectID: id)
            XCTAssertEqual(afterRecovery?.state, .cancelled)
            XCTAssertEqual(afterRecovery?.attemptCount, 0)
        }
    }

    func testExcludedRedownloadSourceIsNotAdmittedByRecovery() async throws {
        let (model, store, ids) = try await fixture([Job(name: "excluded", sequence: 5, snapshot: nil)])
        let id = ids["excluded"]!
        model.setAutomationSettings(WiltedAutomationSettings(refreshPolicy: .manual,
            downloadPolicy: .manual, processingPolicy: .immediate, transcriptPolicy: .bestAvailable, removeAds: true))
        await model.restorePendingPodcastPreparations(in: store, excluding: [id])
        XCTAssertNil(model.podcastPreparationTasks[id])
    }
}

private actor RecoverySleepingRunner: PodcastPipelineRunning {
    private(set) var starts = 0
    func run(request: Data, onProgress: @escaping @Sendable (PodcastPreparationProgress) -> Void) async throws -> Data {
        starts += 1
        try await Task.sleep(for: .seconds(3_600))
        throw CancellationError()
    }
}
