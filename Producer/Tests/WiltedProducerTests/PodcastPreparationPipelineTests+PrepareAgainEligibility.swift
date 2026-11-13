import Foundation
import Testing
import WiltedDomain
@testable import WiltedProducer

/// `podcastEpisodesToPrepareAgain()` offers an episode when its newest attempt
/// did not run on the current engine. Every fixture here is left behind by the
/// real pipeline, with `engineVersion` standing in for an earlier release, so
/// the journal shapes under test are the ones a library really holds.
extension PodcastPreparationPipelineTests {
    static let olderEngine = "podcast-preparation-v11"

    /// The worker's own report for a run that could not resolve an
    /// advertisement. W-INV-013 keeps the whole original, so audio, duration
    /// and removed time say exactly that.
    static func uncertainResponse(audioURL: URL) -> [String: Any] {
        let warning = "original audio includes ads: classifier could not resolve IDs 0"
        var audit: [String: Any] = WorkerStub.cleanAudit()
        audit["unresolvedIds"] = [0]
        audit["incompleteError"] = "classifier could not resolve IDs 0"
        audit["warning"] = warning
        // The uncertain contract requires both diagnostic lists to be present.
        audit["heldSpans"] = [[String: Any]]()
        audit["declinedCommercialEvidenceSeeds"] = [[String: Any]]()
        return [
            "ok": true, "protocolVersion": 2, "timing": "none", "audioPath": audioURL.path,
            "audioChanged": false, "durationSeconds": 12, "removedSeconds": 0.0,
            "adSegments": [[String: Any]](), "keepIntervals": [[String: Any]](),
            "report": ["outcome": "uncertain", "rawNominations": [[String: Any]](),
                       "warning": warning, "audit": audit],
        ]
    }

    @Test func aCutFromAnOlderEngineIsOfferedWithWhatItRemoved() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let cut = try await fixture.pipeline(Fixture.cuttingStub(), engineVersion: Self.olderEngine)
            .prepare(episodeID: fixture.episodeID)

        let candidate = try #require(try await fixture.store.podcastEpisodesToPrepareAgain().first)
        #expect(candidate.episodeID == fixture.episodeID)
        #expect(candidate.readyRevision.revision.revisionID == cut.revision.revisionID)
        #expect(candidate.isCut)
        #expect(candidate.sourceHash == fixture.contentHash)
        #expect(candidate.keptTimeline?.kept.map(\.originalStartSeconds) == [0.0, 7.5])
        #expect(candidate.enclosureURL.absoluteString == "https://cdn.example.test/e1.mp3")
    }

    @Test func anUncertainPreparationOfTheOriginalIsOfferedAsNotCut() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let worker = WorkerStub(response: Self.uncertainResponse(audioURL: fixture.audioURL))
        _ = try await fixture.pipeline(worker, engineVersion: Self.olderEngine).prepare(episodeID: fixture.episodeID)

        let candidate = try #require(try await fixture.store.podcastEpisodesToPrepareAgain().first)
        #expect(!candidate.isCut)
        #expect(candidate.readyRevision.revision.revisionID == fixture.revisionID)
        #expect(candidate.keptTimeline == nil)
        #expect(candidate.sourceHash == nil)

        // The original is only "the existing path" while its file is there.
        try FileManager.default.removeItem(at: fixture.audioURL)
        let withoutFile = try #require(try await fixture.store.podcastEpisodesToPrepareAgain().first)
        #expect(withoutFile.isCut, "with no original on disk the episode has to download it again")
    }

    @Test func aLegacyEngineIsOlderThanTheCurrentOne() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        _ = try await fixture.pipeline(Fixture.cuttingStub(), engineVersion: "unknown-legacy")
            .prepare(episodeID: fixture.episodeID)
        #expect(try await fixture.store.podcastEpisodesToPrepareAgain().map(\.episodeID) == [fixture.episodeID])
    }

    @Test func anEpisodeTheCurrentEngineCutIsNotOffered() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        _ = try await fixture.pipeline(Fixture.cuttingStub()).prepare(episodeID: fixture.episodeID)
        #expect(try await fixture.store.podcastEpisodesToPrepareAgain().isEmpty)
    }

    @Test func anEpisodeTheCurrentEngineCouldNotResolveIsNotOffered() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let worker = WorkerStub(response: Self.uncertainResponse(audioURL: fixture.audioURL))
        let result = try await fixture.pipeline(worker).prepare(episodeID: fixture.episodeID)
        #expect(result.adRemovalOutcome == "uncertain")
        #expect(try await fixture.store.podcastEpisodesToPrepareAgain().isEmpty,
                "running it again would only reach the same answer")
    }

    @Test func aFailedAttemptByTheCurrentEngineCountsAsATry() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        _ = try await fixture.pipeline(Fixture.cuttingStub(), engineVersion: Self.olderEngine)
            .prepare(episodeID: fixture.episodeID)
        #expect(try await fixture.store.podcastEpisodesToPrepareAgain().count == 1)

        await #expect(throws: PodcastPreparationError.self) {
            try await fixture.pipeline(ProbingWorker {}).prepare(episodeID: fixture.episodeID)
        }
        #expect(try await fixture.store.podcastEpisodesToPrepareAgain().isEmpty,
                "the newest attempt failed on the current engine, so its Retry is the next step")
    }

    /// Stopping a run decided nothing, so it cannot stand in for trying.
    @Test func aCancelledAttemptDoesNotCount() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        _ = try await fixture.pipeline(Fixture.cuttingStub(), engineVersion: Self.olderEngine)
            .prepare(episodeID: fixture.episodeID)
        await #expect(throws: (any Error).self) {
            try await fixture.pipeline(CancellingWorker()).prepare(episodeID: fixture.episodeID)
        }
        #expect(try await fixture.store.podcastEpisodesToPrepareAgain().count == 1)
    }

    @Test func aRetiredEpisodeIsNotOffered() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        _ = try await fixture.pipeline(Fixture.cuttingStub(), engineVersion: Self.olderEngine)
            .prepare(episodeID: fixture.episodeID)
        #expect(try await fixture.store.retireEpisode(fixture.episodeID))
        #expect(try await fixture.store.podcastEpisodesToPrepareAgain().isEmpty)
    }

    @Test func aCompletedEpisodeIsNotOffered() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let cut = try await fixture.pipeline(Fixture.cuttingStub(), engineVersion: Self.olderEngine)
            .prepare(episodeID: fixture.episodeID)
        let finished = Timestamp(Date(timeIntervalSince1970: 1_700_000_500))
        try await fixture.store.saveListening(PodcastListeningState(
            episodeID: fixture.episodeID, completedAt: finished,
            lastRevisionID: cut.revision.revisionID, updatedAt: finished))
        #expect(try await fixture.store.podcastEpisodesToPrepareAgain().isEmpty)
    }

    @Test func anInvalidatedOutcomeIsNotOffered() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let cut = try await fixture.pipeline(Fixture.cuttingStub(), engineVersion: Self.olderEngine)
            .prepare(episodeID: fixture.episodeID)
        try await fixture.store.savePreparationOutcome(PodcastPreparationOutcome(
            episodeID: fixture.episodeID, revisionID: cut.revision.revisionID, policyDigest: "digest",
            pipelineFingerprint: nil, semanticVersion: Self.olderEngine,
            producedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_300)),
            eligibility: .invalid, invalidationRuleID: "rule"))
        #expect(try await fixture.store.podcastEpisodesToPrepareAgain().isEmpty)
    }

    // MARK: Labelled digest staleness

    private static let otherLabelledDigest =
        "sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"

    @Test func differingNonEmptyDigestWithDigestInForceIsOffered() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        _ = try await fixture.pipeline(Fixture.cuttingStub()).prepare(episodeID: fixture.episodeID)
        let offered = try await fixture.store.podcastEpisodesToPrepareAgain(
            labelledDigestInForce: { _, _ in Self.otherLabelledDigest })
        #expect(offered.map(\.episodeID) == [fixture.episodeID])
    }

    @Test func equalDigestIsNotOffered() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let result = try await fixture.pipeline(Fixture.cuttingStub()).prepare(episodeID: fixture.episodeID)
        let outcome = try #require(try await fixture.store.preparationOutcome(
            for: fixture.episodeID, revisionID: result.revision.revisionID))
        #expect(try await fixture.store.podcastEpisodesToPrepareAgain(
            labelledDigestInForce: { _, _ in outcome.policyDigest }).isEmpty)
    }

    @Test func emptyRecordedDigestIsNotOfferedForDigestReason() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let result = try await fixture.pipeline(Fixture.cuttingStub()).prepare(episodeID: fixture.episodeID)
        try await fixture.store.savePreparationOutcome(PodcastPreparationOutcome(
            episodeID: fixture.episodeID, revisionID: result.revision.revisionID, policyDigest: "",
            pipelineFingerprint: nil, semanticVersion: PodcastPreparationPipeline.semanticVersion,
            producedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_300))))
        // Clear journalled digest so the empty outcome digest is what eligibility reads.
        try await fixture.store.clearPreparationJournal(
            for: PodcastPreparationPipeline.requestID(for: fixture.episodeID))
        let requestID = PodcastPreparationPipeline.requestID(for: fixture.episodeID)
        try await fixture.store.record(preparation: PreparationJournalEntry(
            id: requestID + "|start", itemID: fixture.episodeID, requestID: requestID,
            status: try PreparationStatus(
                stage: .preparing, detail: "start", cancellable: true,
                emittedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_200)),
                evidence: try PreparationEvidence(
                    kind: LocalLibraryStore.pipelineProvenanceEvidenceKind,
                    fields: [
                        "engineVersion": PodcastPreparationPipeline.semanticVersion,
                        "policyDigest": "",
                    ]))))
        try await fixture.store.record(preparation: PreparationJournalEntry(
            id: requestID + "|terminal", itemID: fixture.episodeID, requestID: requestID,
            status: try PreparationStatus(
                stage: .completed, detail: "Prepared.", cancellable: false,
                terminalResult: PreparationTerminalResult(
                    outcome: .succeeded, revisionID: result.revision.revisionID),
                emittedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_201)),
                evidence: try PreparationEvidence(
                    kind: LocalLibraryStore.pipelineProvenanceEvidenceKind,
                    fields: [
                        "fingerprint": "fp",
                        "engineVersion": PodcastPreparationPipeline.semanticVersion,
                        "policyDigest": "",
                    ]))))
        #expect(try await fixture.store.podcastEpisodesToPrepareAgain(
            labelledDigestInForce: { _, _ in Self.otherLabelledDigest }).isEmpty)
    }

    @Test func nilDigestInForceIsNotOfferedForDigestReason() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        _ = try await fixture.pipeline(Fixture.cuttingStub()).prepare(episodeID: fixture.episodeID)
        #expect(try await fixture.store.podcastEpisodesToPrepareAgain(
            labelledDigestInForce: { _, _ in nil }).isEmpty)
    }

    @Test func labelledRoundTripBecomesEligibleAfterModelChange() async throws {
        let fixture = try await Fixture()
        let (defaults, defaultsName) = makeDefaults()
        let sender = LabellerSenderStub(outcomes: [
            .respond(LabellerResponse(text: mustCutReply(), usage: LabellerUsage()))
        ])
        defer {
            fixture.remove()
            defaults.removePersistentDomain(forName: defaultsName)
        }
        try await saveFeed(in: fixture.store)
        let cue = try writeCueFile(to: fixture.workDirectory)
        let worker = LabelledStageWorker { request, _ in
            if request["adStage"] as? String == "transcript" {
                return ([
                    "ok": true, "adStage": "transcript", "timing": "aligned",
                    "durationSeconds": 12, "labellerCuesPath": cue.path, "labellerCuesDigest": cue.digest,
                ], nil)
            }
            return (Self.cutResponse(audioPath: request["outputPath"] as? String ?? ""), Fixture.cuttingAudio)
        }
        let labelling = configureLabelling(defaults: defaults, sender: sender)
        _ = try await labelledPipeline(fixture, runner: worker, labelling: labelling)
            .prepare(episodeID: fixture.episodeID)
        let policy = PodcastPreparationPolicySnapshot(transcriptPolicy: .bestAvailable, removeAds: true)
        let input = RemoteLabellingInput(
            feedID: Self.labelledFeedID.rawValue, feedURL: Self.labelledFeedURL,
            feedTitle: Self.labelledShowTitle, audioURL: URL(string: "https://cdn.example.test/e1.mp3"),
            removeAds: true)
        let current = LabelledPolicyDigestInForce.digest(
            policy: policy, input: input, preferences: labelling.preferences, hasKey: true)
        #expect(try await fixture.store.podcastEpisodesToPrepareAgain(
            labelledDigestInForce: { _, _ in current }).isEmpty)
        labelling.preferences.modelID = "invented-model-b"
        let after = LabelledPolicyDigestInForce.digest(
            policy: policy, input: input, preferences: labelling.preferences, hasKey: true)
        #expect(current != after)
        #expect(try await fixture.store.podcastEpisodesToPrepareAgain(
            labelledDigestInForce: { _, _ in after }).map(\.episodeID) == [fixture.episodeID])
    }

    /// One routing decision per attempt: a model changed while the run is under way
    /// neither reaches the request nor the recorded digest, so the episode reads as
    /// prepared under the old setting and is offered under the new one.
    @Test func aModelChangedMidRunLeavesTheAttemptOnItsOriginalSetting() async throws {
        let fixture = try await Fixture()
        let (defaults, defaultsName) = makeDefaults()
        let sender = LabellerSenderStub(outcomes: [
            .respond(LabellerResponse(text: mustCutReply(), usage: LabellerUsage()))
        ])
        defer {
            fixture.remove()
            defaults.removePersistentDomain(forName: defaultsName)
        }
        try await saveFeed(in: fixture.store)
        let cue = try writeCueFile(to: fixture.workDirectory)
        let labelling = configureLabelling(defaults: defaults, sender: sender)
        let preferences = labelling.preferences
        let policy = PodcastPreparationPolicySnapshot(transcriptPolicy: .bestAvailable, removeAds: true)
        let input = RemoteLabellingInput(
            feedID: Self.labelledFeedID.rawValue, feedURL: Self.labelledFeedURL,
            feedTitle: Self.labelledShowTitle, audioURL: URL(string: "https://cdn.example.test/e1.mp3"),
            removeAds: true)
        let before = LabelledPolicyDigestInForce.digest(
            policy: policy, input: input, preferences: preferences, hasKey: true)
        let worker = LabelledStageWorker { request, _ in
            if request["adStage"] as? String == "transcript" {
                preferences.modelID = "invented-model-b"
                return ([
                    "ok": true, "adStage": "transcript", "timing": "aligned",
                    "durationSeconds": 12, "labellerCuesPath": cue.path, "labellerCuesDigest": cue.digest,
                ], nil)
            }
            #expect(request["labellerModelID"] as? String == AdLabellerPreferences.defaultModelID)
            return (Self.cutResponse(audioPath: request["outputPath"] as? String ?? ""), Fixture.cuttingAudio)
        }
        let result = try await labelledPipeline(fixture, runner: worker, labelling: labelling)
            .prepare(episodeID: fixture.episodeID)
        let outcome = try #require(try await fixture.store.preparationOutcome(
            for: fixture.episodeID, revisionID: result.revision.revisionID))
        #expect(outcome.policyDigest == before)
        let after = LabelledPolicyDigestInForce.digest(
            policy: policy, input: input, preferences: preferences, hasKey: true)
        #expect(before != after)
        #expect(try await fixture.store.podcastEpisodesToPrepareAgain(
            labelledDigestInForce: { _, _ in before }).isEmpty)
        #expect(try await fixture.store.podcastEpisodesToPrepareAgain(
            labelledDigestInForce: { _, _ in after }).map(\.episodeID) == [fixture.episodeID])
    }

    @Test func labelledStopKeepingOriginalClearsDigestOffer() async throws {
        try await assertLabelledWholeOriginalClearsOffer { cue, fixture in
            LabellerSenderStub(outcomes: [.fail(.modelUnavailable)])
        } worker: { cue, fixture in
            LabelledStageWorker { request, _ in
                if request["adStage"] as? String == "transcript" {
                    return ([
                        "ok": true, "adStage": "transcript", "timing": "aligned",
                        "durationSeconds": 12, "labellerCuesPath": cue.path, "labellerCuesDigest": cue.digest,
                    ], nil)
                }
                return ([
                    "ok": true, "timing": "aligned", "audioPath": fixture.audioURL.path, "audioChanged": false,
                    "durationSeconds": 12, "text": "Kept.", "cues": [[String: Any]](),
                    "removedSeconds": 0, "adSegments": [[String: Any]](), "keepIntervals": [[String: Any]](),
                    "report": ["outcome": "disabled", "rawNominations": [[String: Any]]()],
                ], nil)
            }
        }
    }

    @Test func labelledCueMismatchWholeOriginalClearsDigestOffer() async throws {
        try await assertLabelledWholeOriginalClearsOffer { _, _ in
            LabellerSenderStub(outcomes: [
                .respond(LabellerResponse(text: mustCutReply(), usage: LabellerUsage())),
                .respond(LabellerResponse(text: mustCutReply(), usage: LabellerUsage())),
            ])
        } worker: { cue, fixture in
            LabelledStageWorker { request, _ in
                let stage = request["adStage"] as? String
                if stage == "transcript" {
                    return ([
                        "ok": true, "adStage": "transcript", "timing": "aligned",
                        "durationSeconds": 12, "labellerCuesPath": cue.path, "labellerCuesDigest": cue.digest,
                    ], nil)
                }
                if stage == "cut" {
                    return ([
                        "ok": false, "code": "labelled-cues-mismatch",
                        "message": "aligned transcript digest does not match labellerCuesDigest",
                    ], nil)
                }
                return ([
                    "ok": true, "timing": "aligned", "audioPath": fixture.audioURL.path, "audioChanged": false,
                    "durationSeconds": 12, "text": "Kept.", "cues": [[String: Any]](),
                    "removedSeconds": 0, "adSegments": [[String: Any]](), "keepIntervals": [[String: Any]](),
                    "report": ["outcome": "disabled", "rawNominations": [[String: Any]]()],
                ], nil)
            }
        }
    }

    @Test func prepareAgainKeptClearsDigestOffer() async throws {
        let fixture = try await Fixture()
        let (defaults, defaultsName) = makeDefaults()
        let sender = LabellerSenderStub(outcomes: [
            .respond(LabellerResponse(text: mustCutReply(), usage: LabellerUsage())),
            .respond(LabellerResponse(text: mustCutReply(), usage: LabellerUsage())),
        ])
        defer {
            fixture.remove()
            defaults.removePersistentDomain(forName: defaultsName)
        }
        try await saveFeed(in: fixture.store)
        let cue = try writeCueFile(to: fixture.workDirectory)
        let cutWorker = LabelledStageWorker { request, _ in
            if request["adStage"] as? String == "transcript" {
                return ([
                    "ok": true, "adStage": "transcript", "timing": "aligned",
                    "durationSeconds": 12, "labellerCuesPath": cue.path, "labellerCuesDigest": cue.digest,
                ], nil)
            }
            return (Self.cutResponse(audioPath: request["outputPath"] as? String ?? ""), Fixture.cuttingAudio)
        }
        let labelling = configureLabelling(defaults: defaults, sender: sender)
        _ = try await labelledPipeline(fixture, runner: cutWorker, labelling: labelling)
            .prepare(episodeID: fixture.episodeID)
        labelling.preferences.modelID = "invented-model-b"
        let policy = PodcastPreparationPolicySnapshot(transcriptPolicy: .bestAvailable, removeAds: true)
        let input = RemoteLabellingInput(
            feedID: Self.labelledFeedID.rawValue, feedURL: Self.labelledFeedURL,
            feedTitle: Self.labelledShowTitle, audioURL: URL(string: "https://cdn.example.test/e1.mp3"),
            removeAds: true)
        let stale = LabelledPolicyDigestInForce.digest(
            policy: policy, input: input, preferences: labelling.preferences, hasKey: true)
        #expect(try await fixture.store.podcastEpisodesToPrepareAgain(
            labelledDigestInForce: { _, _ in stale }).count == 1)
        let candidate = try #require(try await fixture.store.podcastEpisodesToPrepareAgain(
            labelledDigestInForce: { _, _ in stale }).first)
        let staged = try fixture.staged(Fixture.originalBody)
        let keepWorker = LabelledStageWorker { request, _ in
            if request["adStage"] as? String == "transcript" {
                return ([
                    "ok": true, "adStage": "transcript", "timing": "aligned",
                    "durationSeconds": 12, "labellerCuesPath": cue.path, "labellerCuesDigest": cue.digest,
                ], nil)
            }
            return (Self.shareCeilingResponseForEligibility(audioPath: staged.url.path), nil)
        }
        let keepLabelling = configureLabelling(
            defaults: defaults, sender: LabellerSenderStub(outcomes: [
                .respond(LabellerResponse(text: mustCutReply(), usage: LabellerUsage()))
            ]), modelID: "invented-model-b")
        _ = try await labelledPipeline(fixture, runner: keepWorker, labelling: keepLabelling)
            .prepareAgain(candidate: candidate, stage: { staged }, policy: policy)
        let after = LabelledPolicyDigestInForce.digest(
            policy: policy, input: input, preferences: keepLabelling.preferences, hasKey: true)
        #expect(try await fixture.store.podcastEpisodesToPrepareAgain(
            labelledDigestInForce: { _, _ in after }).isEmpty)
    }

    @Test func episodeAudioThatForcesLocalIsNotOfferedForDigestReason() async throws {
        let fixture = try await Fixture()
        let (defaults, defaultsName) = makeDefaults()
        let sender = LabellerSenderStub(outcomes: [
            .respond(LabellerResponse(text: mustCutReply(), usage: LabellerUsage()))
        ])
        defer {
            fixture.remove()
            defaults.removePersistentDomain(forName: defaultsName)
        }
        try await saveFeed(in: fixture.store)
        let cue = try writeCueFile(to: fixture.workDirectory)
        let worker = LabelledStageWorker { request, _ in
            if request["adStage"] as? String == "transcript" {
                return ([
                    "ok": true, "adStage": "transcript", "timing": "aligned",
                    "durationSeconds": 12, "labellerCuesPath": cue.path, "labellerCuesDigest": cue.digest,
                ], nil)
            }
            return (Self.cutResponse(audioPath: request["outputPath"] as? String ?? ""), Fixture.cuttingAudio)
        }
        let labelling = configureLabelling(defaults: defaults, sender: sender)
        _ = try await labelledPipeline(fixture, runner: worker, labelling: labelling)
            .prepare(episodeID: fixture.episodeID)
        labelling.preferences.modelID = "invented-model-b"
        let credentialed = URL(string: "https://cdn.example.invalid/e1.mp3?token=secret-token-value")!
        #expect(try await fixture.store.podcastEpisodesToPrepareAgain(
            labelledDigestInForce: { feedID, _ in
                let policy = PodcastPreparationPolicySnapshot(transcriptPolicy: .bestAvailable, removeAds: true)
                return LabelledPolicyDigestInForce.digest(
                    policy: policy,
                    input: RemoteLabellingInput(
                        feedID: feedID.rawValue, feedURL: Self.labelledFeedURL,
                        feedTitle: Self.labelledShowTitle, audioURL: credentialed, removeAds: true),
                    preferences: labelling.preferences, hasKey: true)
            }).isEmpty)
    }

    @Test func dailyCapDoesNotChangeEligibility() async throws {
        let fixture = try await Fixture()
        let (defaults, defaultsName) = makeDefaults()
        let sender = LabellerSenderStub(outcomes: [
            .respond(LabellerResponse(text: mustCutReply(), usage: LabellerUsage()))
        ])
        defer {
            fixture.remove()
            defaults.removePersistentDomain(forName: defaultsName)
        }
        try await saveFeed(in: fixture.store)
        let cue = try writeCueFile(to: fixture.workDirectory)
        let worker = LabelledStageWorker { request, _ in
            if request["adStage"] as? String == "transcript" {
                return ([
                    "ok": true, "adStage": "transcript", "timing": "aligned",
                    "durationSeconds": 12, "labellerCuesPath": cue.path, "labellerCuesDigest": cue.digest,
                ], nil)
            }
            return (Self.cutResponse(audioPath: request["outputPath"] as? String ?? ""), Fixture.cuttingAudio)
        }
        let labelling = configureLabelling(defaults: defaults, sender: sender)
        _ = try await labelledPipeline(fixture, runner: worker, labelling: labelling)
            .prepare(episodeID: fixture.episodeID)
        let policy = PodcastPreparationPolicySnapshot(transcriptPolicy: .bestAvailable, removeAds: true)
        let input = RemoteLabellingInput(
            feedID: Self.labelledFeedID.rawValue, feedURL: Self.labelledFeedURL,
            feedTitle: Self.labelledShowTitle, audioURL: URL(string: "https://cdn.example.test/e1.mp3"),
            removeAds: true)
        let before = LabelledPolicyDigestInForce.digest(
            policy: policy, input: input, preferences: labelling.preferences, hasKey: true)
        #expect(try await fixture.store.podcastEpisodesToPrepareAgain(
            labelledDigestInForce: { _, _ in before }).isEmpty)
        labelling.preferences.dailyCap = 0
        #expect(LabellerRequestCounter(preferences: defaults).hasReachedCap)
        let atCap = LabelledPolicyDigestInForce.digest(
            policy: policy, input: input, preferences: labelling.preferences, hasKey: true)
        #expect(before == atCap)
        #expect(try await fixture.store.podcastEpisodesToPrepareAgain(
            labelledDigestInForce: { _, _ in atCap }).isEmpty)
    }

    private func assertLabelledWholeOriginalClearsOffer(
        sender: (WriteCue, Fixture) -> LabellerSenderStub,
        worker: (WriteCue, Fixture) -> LabelledStageWorker
    ) async throws {
        let fixture = try await Fixture()
        let (defaults, defaultsName) = makeDefaults()
        defer {
            fixture.remove()
            defaults.removePersistentDomain(forName: defaultsName)
        }
        try await saveFeed(in: fixture.store)
        let cue = try writeCueFile(to: fixture.workDirectory)
        let labelling = configureLabelling(
            defaults: defaults, sender: sender(cue, fixture))
        labelling.preferences.waitLimit = 60
        _ = try await labelledPipeline(
            fixture, runner: worker(cue, fixture), labelling: labelling)
            .prepare(episodeID: fixture.episodeID)
        let policy = PodcastPreparationPolicySnapshot(transcriptPolicy: .bestAvailable, removeAds: true)
        let input = RemoteLabellingInput(
            feedID: Self.labelledFeedID.rawValue, feedURL: Self.labelledFeedURL,
            feedTitle: Self.labelledShowTitle, audioURL: URL(string: "https://cdn.example.test/e1.mp3"),
            removeAds: true)
        let digest = LabelledPolicyDigestInForce.digest(
            policy: policy, input: input, preferences: labelling.preferences, hasKey: true)
        #expect(try await fixture.store.podcastEpisodesToPrepareAgain(
            labelledDigestInForce: { _, _ in digest }).isEmpty)
    }

    private typealias WriteCue = (path: String, digest: String, cues: [LabellerCue])

    private static func shareCeilingResponseForEligibility(audioPath: String) -> [String: Any] {
        let warning = "original audio includes ads: unresolved commercial spans"
        return [
            "ok": true, "adStage": "cut", "timing": "aligned", "audioPath": audioPath,
            "audioChanged": false, "durationSeconds": 12,
            "text": "Whole original.", "cues": [["startSeconds": 0.0, "endSeconds": 12.0, "text": "Whole."]],
            "removedSeconds": 0, "adSegments": [[String: Any]](), "keepIntervals": [[String: Any]](),
            "report": [
                "outcome": "uncertain",
                "warning": warning,
                "rawNominations": [[String: Any]](),
                "audit": [
                    "adEngine": "labelled",
                    "breaksProposed": 1, "breaksCut": 0, "breaksLeftIn": 0,
                    "leftIn": [[String: Any]](),
                    "labellerModelID": AdLabellerPreferences.defaultModelID,
                    "labellerLevel": AdLabellerPreferences.defaultLevel,
                    "labellerPromptVersion": EpisodeLabeller.promptVersion,
                    "heldSpans": [["reason": "total-share-ceiling", "startSeconds": 3.0, "endSeconds": 10.0]],
                    "incompleteError": "unresolved commercial spans",
                    "warning": warning,
                    "unresolvedIds": [Int](),
                    "modelRequests": 0, "modelFailures": 0, "experimentalRequests": 0,
                    "classifierRequests": 0, "classifierValidRequests": 0, "classifierInvalidRequests": 0,
                    "exhaustedSingletonLineages": 0,
                    "candidates": [[String: Any]](),
                    "declinedCommercialEvidenceSeeds": [[String: Any]](),
                ],
            ],
        ]
    }
}

/// A worker whose run is stopped by the listener.
actor CancellingWorker: PodcastPipelineRunning {
    func run(
        request payload: Data,
        onProgress: @escaping @Sendable (PodcastPreparationProgress) -> Void
    ) async throws -> Data {
        throw CancellationError()
    }
}
