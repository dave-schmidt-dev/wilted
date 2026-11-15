import Foundation
import Testing
import WiltedDomain
@testable import WiltedProducer

/// A feed marked as having no ads after the current engine already cut some of
/// its episodes: those cuts were programme, so the episodes are offered again
/// and a run with ad removal off puts the whole original back. Every fixture is
/// left behind by the real pipeline.
extension PodcastPreparationPipelineTests {
    // MARK: Helpers

    private static let adRemovalOff = PodcastPreparationPolicySnapshot(
        transcriptPolicy: .noLocalSTT, removeAds: false)

    /// A running ticket's identity, as the app hands each run: with one the
    /// journal keeps earlier attempts beside the new one instead of clearing them.
    private func attempt(_ fixture: Fixture, sequence: Int) async throws -> PreparationAttemptIdentity {
        let ticket = try await fixture.store.readmitWorkTicket(
            kind: .podcastPreparation, subjectID: fixture.episodeID.rawValue, requestSequence: sequence,
            to: .running, at: Timestamp(Date(timeIntervalSince1970: 1_700_000_150)))
        return try PreparationAttemptIdentity(
            requestSequence: ticket.requestSequence, attemptCount: ticket.attemptCount)
    }

    private func feedID() throws -> ItemID {
        try ItemID.derivePodcastFeed(from: try #require(URL(string: "https://feeds.example.test/show.xml")))
    }

    /// An episode the current engine cut, listened to up to `position` on the cut.
    private func currentCut(_ fixture: Fixture, position: Double?) async throws -> PodcastPreparationResult {
        let cut = try await fixture.pipeline(Fixture.cuttingStub()).prepare(
            episodeID: fixture.episodeID, attempt: try await attempt(fixture, sequence: 1))
        if let position {
            try await fixture.store.save(playback: try PlaybackState(
                itemID: fixture.episodeID, revisionID: cut.revision.revisionID, sessionID: "session-1",
                sequence: 4, positionSeconds: position, durationSeconds: 7.5, completed: false,
                intent: .progress, deviceID: "mac-1",
                updatedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_250))))
        }
        return cut
    }

    // MARK: Cases

    @Test func aCurrentEngineCutOnAnAdFreeFeedIsOfferedAndRestoredWhole() async throws {
        let fixture = try await Fixture(labelled: true)
        defer { fixture.remove() }
        let adFree: Set<ItemID> = [try feedID()]
        let cut = try await currentCut(fixture, position: 4.5)
        #expect(try await fixture.store.podcastEpisodesToPrepareAgain().isEmpty,
                "without the ad-free mark the current engine's cut is final")

        let offered = try await fixture.store.podcastEpisodesToPrepareAgain(restoringCutsOnFeeds: adFree)
        let target = try #require(offered.first)
        #expect(offered.count == 1)
        #expect(target.readyRevision.revision.revisionID == cut.revision.revisionID)
        #expect(target.isCut)
        #expect(target.sourceHash == fixture.contentHash)
        #expect(target.keptTimeline?.kept.map(\.originalStartSeconds) == [0.0, 7.5])

        let staged = try fixture.staged(Fixture.originalBody)
        let worker = WorkerStub(response: Self.uncutResponse(audioURL: staged.url))
        let outcome = try await fixture.pipeline(worker).prepareAgain(
            candidate: target, stage: { staged }, policy: Self.adRemovalOff, attempt: try await attempt(fixture, sequence: 2))
        guard case .prepared(let result) = outcome else { Issue.record("expected a result, got \(outcome)"); return }

        let asked = try #require(await worker.lastRequest())
        let request = try #require(try JSONSerialization.jsonObject(with: asked) as? [String: Any])
        #expect(request["removeAds"] as? Bool == false)
        #expect(result.adRemovalOutcome == "disabled")
        #expect(try Data(contentsOf: result.mediaURL) == Fixture.originalBody)
        #expect(result.revision.contentHash == fixture.contentHash)
        // 4.5 on the cut is 9.0 on the original: the cut dropped 3.0-7.5.
        #expect(try await fixture.store.playbackState(
            for: fixture.episodeID, revisionID: result.revision.revisionID)?.positionSeconds == 9.0)
        #expect(try await fixture.store.revisions(for: fixture.episodeID).map(\.revisionID)
            == [result.revision.revisionID])

        #expect(try await fixture.store.podcastEpisodesToPrepareAgain(restoringCutsOnFeeds: adFree).isEmpty,
                "a restored episode has nothing left to put back")
    }

    @Test func aCurrentEngineCutOnAnotherFeedIsNotOffered() async throws {
        let fixture = try await Fixture(labelled: true)
        defer { fixture.remove() }
        _ = try await currentCut(fixture, position: nil)
        let other = try ItemID.derivePodcastFeed(
            from: try #require(URL(string: "https://feeds.example.test/another.xml")))
        #expect(try await fixture.store.podcastEpisodesToPrepareAgain(restoringCutsOnFeeds: [other]).isEmpty)
    }

    @Test func anAdFreeFeedsEpisodeWithNothingRemovedIsNotOffered() async throws {
        let fixture = try await Fixture(labelled: true)
        defer { fixture.remove() }
        let worker = WorkerStub(response: Self.uncutResponse(audioURL: fixture.audioURL))
        let result = try await fixture.pipeline(worker).prepare(episodeID: fixture.episodeID)
        #expect(result.adRemovalOutcome == "noAds")
        #expect(try await fixture.store.podcastEpisodesToPrepareAgain(restoringCutsOnFeeds: [try feedID()]).isEmpty)
    }

    @Test func anAdFreeFeedsUnresolvedEpisodeIsNotOffered() async throws {
        let fixture = try await Fixture(labelled: true)
        defer { fixture.remove() }
        let worker = WorkerStub(response: Fixture.labelledUncertainResponse(audioPath: fixture.audioURL.path))
        _ = try await fixture.pipeline(worker).prepare(episodeID: fixture.episodeID)
        #expect(try await fixture.store.podcastEpisodesToPrepareAgain(restoringCutsOnFeeds: [try feedID()]).isEmpty,
                "the whole original was kept, so there is nothing to restore")
    }

    /// An unprovable file counts as a cut for safety everywhere else; here it
    /// must not, or a restored original whose download record drifted would be
    /// offered for ever.
    @Test func aRestoredEpisodeWhoseFileWentMissingIsNotOfferedAgain() async throws {
        let fixture = try await Fixture(labelled: true)
        defer { fixture.remove() }
        let adFree: Set<ItemID> = [try feedID()]
        _ = try await currentCut(fixture, position: nil)
        let target = try #require(
            try await fixture.store.podcastEpisodesToPrepareAgain(restoringCutsOnFeeds: adFree).first)
        let staged = try fixture.staged(Fixture.originalBody)
        let outcome = try await fixture.pipeline(WorkerStub(response: Self.uncutResponse(audioURL: staged.url)))
            .prepareAgain(candidate: target, stage: { staged }, policy: Self.adRemovalOff,
                          attempt: try await attempt(fixture, sequence: 2))
        guard case .prepared(let result) = outcome else { Issue.record("expected a result, got \(outcome)"); return }

        try FileManager.default.removeItem(at: result.mediaURL)
        #expect(try await fixture.store.podcastEpisodesToPrepareAgain(restoringCutsOnFeeds: adFree).isEmpty)
    }

    @Test func anOlderEnginesCutIsOfferedWhetherOrNotTheFeedIsAdFree() async throws {
        let fixture = try await Fixture(labelled: true)
        defer { fixture.remove() }
        _ = try await fixture.pipeline(Fixture.cuttingStub(), engineVersion: Self.olderEngine)
            .prepare(episodeID: fixture.episodeID)
        #expect(try await fixture.store.podcastEpisodesToPrepareAgain().count == 1)
        #expect(try await fixture.store.podcastEpisodesToPrepareAgain(restoringCutsOnFeeds: [try feedID()]).count == 1)
    }

    /// A refusal changes nothing, so the cut is still there to restore.
    @Test func aRefusedRestoreStaysOffered() async throws {
        let fixture = try await Fixture(labelled: true)
        defer { fixture.remove() }
        let adFree: Set<ItemID> = [try feedID()]
        let cut = try await currentCut(fixture, position: 4.5)
        let target = try #require(
            try await fixture.store.podcastEpisodesToPrepareAgain(restoringCutsOnFeeds: adFree).first)
        let staged = try fixture.staged(Self.changedOriginal)
        let outcome = try await fixture.pipeline(WorkerStub(response: Self.uncutResponse(audioURL: staged.url)))
            .prepareAgain(candidate: target, stage: { staged }, policy: Self.adRemovalOff,
                          attempt: try await attempt(fixture, sequence: 2))
        guard case .refused(let reason) = outcome else { Issue.record("expected a refusal, got \(outcome)"); return }
        #expect(reason == .publisherFileChanged)

        let again = try await fixture.store.podcastEpisodesToPrepareAgain(restoringCutsOnFeeds: adFree)
        #expect(again.map(\.readyRevision.revision.revisionID) == [cut.revision.revisionID])
    }

    @Test func aFinishedEpisodeOnAnAdFreeFeedIsNotOffered() async throws {
        let fixture = try await Fixture(labelled: true)
        defer { fixture.remove() }
        let cut = try await currentCut(fixture, position: nil)
        let finished = Timestamp(Date(timeIntervalSince1970: 1_700_000_500))
        try await fixture.store.saveListening(PodcastListeningState(
            episodeID: fixture.episodeID, completedAt: finished,
            lastRevisionID: cut.revision.revisionID, updatedAt: finished))
        #expect(try await fixture.store.podcastEpisodesToPrepareAgain(restoringCutsOnFeeds: [try feedID()]).isEmpty)
    }

    // MARK: Not sent for ad finding

    /// An older engine's labelled cut, offered for Prepare Again.
    private func olderLabelledCut(_ fixture: Fixture) async throws -> PodcastPrepareAgainCandidate {
        _ = try await fixture.pipeline(Fixture.cuttingStub(), engineVersion: Self.olderEngine)
            .prepare(episodeID: fixture.episodeID)
        return try #require(try await fixture.store.podcastEpisodesToPrepareAgain().first)
    }

    @Test func prepareAgainOnANotSentShowKeepsTheExistingCutAndSaysWhy() async throws {
        let fixture = try await Fixture(labelled: true)
        defer { fixture.remove() }
        let candidate = try await olderLabelledCut(fixture)
        let services = try #require(fixture.labelling)
        services.preferences.isEnabled = false
        let staged = try fixture.staged(Fixture.originalBody)
        let worker = WorkerStub(response: Self.uncutResponse(audioURL: staged.url))
        let outcome = try await fixture.pipeline(worker).prepareAgain(candidate: candidate, stage: { staged })

        guard case .keptExisting(let summary) = outcome else {
            Issue.record("expected the cut to be kept, got \(outcome)"); return
        }
        #expect(summary == "Kept the existing cut. Online ad finding is off.")
        #expect(summary.contains(RemoteLabellingNotSent.switchOff.sentence))
        #expect(fixture.sender?.requestCount == 1, "only the first cut was sent")
        let ready = try #require(try await fixture.store.readyRevision(for: fixture.episodeID))
        #expect(ready.revision.revisionID == candidate.readyRevision.revision.revisionID)
        let asked = try #require(await worker.lastRequest())
        let request = try #require(try JSONSerialization.jsonObject(with: asked) as? [String: Any])
        #expect(request["removeAds"] as? Bool == false)
    }

    /// The not-sent wording leaves a labelled stop's summary as it was.
    @Test func prepareAgainAfterALabelledStopKeepsItsSummary() async throws {
        let fixture = try await Fixture(labelled: true)
        defer { fixture.remove() }
        let candidate = try await olderLabelledCut(fixture)
        try #require(fixture.labelling).preferences.dailyCap = 0
        let staged = try fixture.staged(Fixture.originalBody)
        let outcome = try await fixture.pipeline(WorkerStub(response: Self.uncutResponse(audioURL: staged.url)))
            .prepareAgain(candidate: candidate, stage: { staged })

        guard case .keptExisting(let summary) = outcome else {
            Issue.record("expected the cut to be kept, got \(outcome)"); return
        }
        #expect(summary == "Kept the existing cut: the current engine could not tell which parts were ads")
    }

    /// A run kept whole while its show was not confirmed recorded the plain
    /// digest, so confirming the show puts a labelled digest in force and the
    /// episode is offered again.
    @Test func anEpisodeKeptWholeWhileUnconfirmedIsOfferedOnceConfirmed() async throws {
        let fixture = try await Fixture(labelled: true)
        defer { fixture.remove() }
        let services = try #require(fixture.labelling)
        let feed = try feedID()
        services.preferences.setConfirmed(feedID: feed.rawValue, false)
        let result = try await fixture.pipeline(WorkerStub(response: Self.uncutResponse(audioURL: fixture.audioURL)))
            .prepare(episodeID: fixture.episodeID)
        #expect(result.adRemovalOutcome == "uncertain")

        let episode = try #require(try await fixture.store.podcastEpisode(for: fixture.episodeID))
        let input = RemoteLabellingInput(
            feedID: feed.rawValue, feedURL: try #require(URL(string: Fixture.feedAddress)),
            feedTitle: Fixture.labelledShowTitle, audioURL: episode.enclosureURL)
        let policy = PodcastPreparationPolicySnapshot(transcriptPolicy: .bestAvailable, removeAds: true)
        func inForce() -> String? {
            LabelledPolicyDigestInForce.digest(
                policy: policy, input: input, preferences: services.preferences, hasKey: services.keyStore.hasKey())
        }
        #expect(inForce() == nil)
        let unconfirmed = inForce()
        #expect(try await fixture.store.podcastEpisodesToPrepareAgain(labelledDigestInForce: { _, _ in unconfirmed })
            .isEmpty)

        services.preferences.setConfirmed(feedID: feed.rawValue, true)
        let confirmed = try #require(inForce())
        let offered = try await fixture.store.podcastEpisodesToPrepareAgain(labelledDigestInForce: { _, _ in confirmed })
        #expect(offered.map(\.episodeID) == [fixture.episodeID])
        #expect(offered.first?.isCut == false, "the whole original was kept")
    }
}
