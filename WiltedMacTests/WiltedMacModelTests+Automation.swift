import CryptoKit
import Foundation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

extension WiltedMacModelTests {
    // MARK: Automation settings

    func automationSettingsPreferences() throws -> UserDefaults {
        let suite = "com.zerodelta.wilted.mac.automation-settings-tests"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        preferences.removePersistentDomain(forName: suite)
        return preferences
    }

    func offPeakWindow() throws -> WiltedAutomationOffPeakWindow {
        let start = try XCTUnwrap(WiltedAutomationLocalTime(hour: 22, minute: 30))
        let end = try XCTUnwrap(WiltedAutomationLocalTime(hour: 6, minute: 15))
        return try XCTUnwrap(WiltedAutomationOffPeakWindow(start: start, end: end))
    }

    func localDate(hour: Int, minute: Int = 0) throws -> Date {
        try XCTUnwrap(Calendar.current.date(from: DateComponents(
            year: 2026, month: 9, day: 6, hour: hour, minute: minute
        )))
    }

    func automationFixture(_ suffix: String) throws -> (URL, WiltedMacModel, WiltedMacEpisode) {
        let directory = temporaryDirectory(suffix)
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts"],
            stateDirectoryOverride: directory,
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        return (directory, model, try XCTUnwrap(model.episodes.first))
    }

    func testAutomaticAdmissionStartsImmediatePreparation() async throws {
        let (directory, model, episode) = try automationFixture("automatic-immediate")
        defer { try? FileManager.default.removeItem(at: directory) }
        model.setAutomationSettings(WiltedAutomationSettings(
            refreshPolicy: .manual, downloadPolicy: .manual, processingPolicy: .immediate,
            transcriptPolicy: .alwaysTranscribe, removeAds: false
        ))

        model.admitAutomaticPreparation(for: episode, at: try localDate(hour: 12))

        XCTAssertTrue(model.episodes.first(where: { $0.id == episode.id })?.preparationState.isRunning == true)
        XCTAssertTrue(model.deferredAutomaticPreparations.isEmpty)
        XCTAssertTrue(model.preparationQueue.isEmpty)
        try await Task.sleep(for: .milliseconds(10))
    }

    func testAutomaticAdmissionSkipsPreparationUnderManualPolicy() throws {
        let (directory, model, episode) = try automationFixture("automatic-manual")
        defer { try? FileManager.default.removeItem(at: directory) }
        model.setAutomationSettings(WiltedAutomationSettings(
            refreshPolicy: .manual, downloadPolicy: .manual, processingPolicy: .manual,
            transcriptPolicy: .alwaysTranscribe, removeAds: false
        ))

        model.admitAutomaticPreparation(for: episode, at: try localDate(hour: 12))

        XCTAssertEqual(
            model.episodes.first(where: { $0.id == episode.id })?.preparationState,
            .notPrepared
        )
        XCTAssertTrue(model.deferredAutomaticPreparations.isEmpty)
        XCTAssertTrue(model.preparationQueue.isEmpty)
    }

    /// A deferred job is stored as `.preparing(stage: "Queued")`, which makes
    /// `isRunning` true, so the row is indistinguishable from one actually
    /// being prepared unless something else answers the question.
    func testADeferredEpisodeIsDistinguishableFromOneBeingPrepared() throws {
        let (directory, model, episode) = try automationFixture("deferred-is-distinguishable")
        defer { try? FileManager.default.removeItem(at: directory) }
        model.setAutomationSettings(WiltedAutomationSettings(
            refreshPolicy: .manual, downloadPolicy: .manual,
            processingPolicy: .offPeak(try offPeakWindow()),
            transcriptPolicy: .alwaysTranscribe, removeAds: false
        ))
        XCTAssertFalse(model.isDeferredForOffPeak(episode.id))

        model.admitAutomaticPreparation(for: episode, at: try localDate(hour: 12))

        XCTAssertTrue(model.isDeferredForOffPeak(episode.id))
        XCTAssertEqual(model.episodes.first(where: { $0.id == episode.id })?.preparationState,
                       .preparing(stage: WiltedMacModel.preparationQueuedStage),
                       "the stored state alone still reads as running, which is why the row "
                       + "needs isDeferredForOffPeak rather than preparationState")
    }

    /// The off-peak window is a default, not a rule: a listener about to leave
    /// should not have to edit a Settings policy and wait for the next
    /// re-evaluation to get this one episode prepared.
    func testPreparingADeferredEpisodeNowTakesItOutOfTheOffPeakQueue() throws {
        let (directory, model, episode) = try automationFixture("prepare-now-overrides")
        defer { try? FileManager.default.removeItem(at: directory) }
        model.setAutomationSettings(WiltedAutomationSettings(
            refreshPolicy: .manual, downloadPolicy: .manual,
            processingPolicy: .offPeak(try offPeakWindow()),
            transcriptPolicy: .alwaysTranscribe, removeAds: false
        ))
        model.admitAutomaticPreparation(for: episode, at: try localDate(hour: 12))
        XCTAssertEqual(model.preparationQueue.entries.map(\.id), [episode.id])

        XCTAssertTrue(model.prepareDeferredEpisodeNow(episode))

        XCTAssertFalse(model.isDeferredForOffPeak(episode.id),
                       "the episode is being prepared now, so nothing should still be holding "
                       + "it for a window hours away")
        XCTAssertTrue(model.deferredAutomaticPreparations.isEmpty)
    }

    /// The Mac UI suite reaches Prepare now only through a fixture launch, so
    /// the deferral the fixture seeds has to survive initialisation. It did not:
    /// `installFixture` runs before the stored preferences are read, and a
    /// fixture host has nothing stored, so the load emptied the seed before the
    /// first render and the control never appeared.
    func testADeferredFixtureLaunchStillHoldsItsDeferralAfterInitialisation() throws {
        let directory = temporaryDirectory("deferred-fixture-survives-init")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts",
                        "--wilted-ui-fixture-deferred"],
            stateDirectoryOverride: directory, preferences: WiltedMacTestPreferences.ephemeral()
        )
        let deferredID = try XCTUnwrap(model.deferredAutomaticPreparations.first?.episodeID,
                                       "a --wilted-ui-fixture-deferred launch must reach the "
                                       + "first render still holding its deferral, or Prepare "
                                       + "now has nothing to override")
        let episode = try XCTUnwrap(model.episodes.first { $0.id == deferredID })
        XCTAssertTrue(model.isDeferredForOffPeak(episode.id))
        XCTAssertEqual(WiltedMacModel.menuGroup(for: episode), .downloaded,
                       "the deferred row sits in the group whose control offers Prepare now")

        // The UI leg does not reach the Menu directly: it opens Feeds and
        // presses the first Keep. Replaying that here keeps this a proxy for
        // the journey rather than for initialisation alone.
        let kept = try XCTUnwrap(model.feedsEpisodes.first,
                                 "Feeds must offer the row the leg keeps")
        model.keepEpisode(kept)
        XCTAssertEqual(kept.id, deferredID,
                       "the leg keeps the first Feeds row, so that row has to be the deferred "
                       + "one or the Menu never draws a Prepare now control")
        XCTAssertTrue(model.isDeferredForOffPeak(deferredID),
                      "keeping the episode must not clear its deferral")
    }

    /// An episode nothing deferred has no deferral to override, and saying so
    /// keeps the control from appearing to do something on a row it cannot act on.
    func testPreparingANonDeferredEpisodeNowReportsThatItDidNothing() throws {
        let (directory, model, episode) = try automationFixture("prepare-now-no-deferral")
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertFalse(model.prepareDeferredEpisodeNow(episode))
        XCTAssertTrue(model.preparationQueue.isEmpty)
    }

    func testSkippingAnEpisodeGivesUpItsPlaceInThePreparationQueue() throws {
        let (directory, model, episode) = try automationFixture("skip-leaves-queue")
        defer { try? FileManager.default.removeItem(at: directory) }
        model.setAutomationSettings(WiltedAutomationSettings(
            refreshPolicy: .manual, downloadPolicy: .manual,
            processingPolicy: .offPeak(try offPeakWindow()),
            transcriptPolicy: .alwaysTranscribe, removeAds: false
        ))
        model.admitAutomaticPreparation(for: episode, at: try localDate(hour: 12))
        XCTAssertEqual(model.preparationQueue.entries.map(\.id), [episode.id])

        model.removeEpisode(episode)

        XCTAssertTrue(model.preparationQueue.isEmpty,
                      "a removed episode kept its turn, so Prep counted one more waiting than "
                      + "the Larder could show and the run slot went to a row nobody has")
    }

    func testOffPeakAdmissionKeepsItsOriginalWindowAndSnapshotUntilEligible() async throws {
        let (directory, model, episode) = try automationFixture("automatic-off-peak")
        defer { try? FileManager.default.removeItem(at: directory) }
        let originalWindow = try offPeakWindow()
        let originalSettings = WiltedAutomationSettings(
            refreshPolicy: .manual, downloadPolicy: .manual, processingPolicy: .offPeak(originalWindow),
            transcriptPolicy: .alwaysTranscribe, removeAds: false
        )
        model.setAutomationSettings(originalSettings)

        model.admitAutomaticPreparation(for: episode, at: try localDate(hour: 12))

        let admitted = try XCTUnwrap(model.deferredAutomaticPreparations.first)
        XCTAssertEqual(admitted.episodeID, episode.id)
        XCTAssertEqual(admitted.processingPolicy, .offPeak(originalWindow))
        XCTAssertEqual(admitted.policySnapshot, PodcastPreparationPolicySnapshot(
            transcriptPolicy: .alwaysTranscribe, removeAds: false
        ))
        XCTAssertEqual(model.preparationQueue.entries.map(\.id), [episode.id])
        XCTAssertEqual(
            model.episodes.first(where: { $0.id == episode.id })?.preparationState,
            .preparing(stage: WiltedMacModel.preparationQueuedStage)
        )

        model.setAutomationSettings(WiltedAutomationSettings(
            refreshPolicy: .manual, downloadPolicy: .manual, processingPolicy: .manual,
            transcriptPolicy: .noLocalSTT, removeAds: true
        ))
        model.startEligibleAutomaticPreparations(at: try localDate(hour: 21))
        XCTAssertEqual(model.deferredAutomaticPreparations, [admitted],
                       "later settings cannot skip or rewrite the admitted job")

        model.startEligibleAutomaticPreparations(at: try localDate(hour: 23))
        XCTAssertTrue(model.deferredAutomaticPreparations.isEmpty)
        XCTAssertTrue(model.preparationQueue.isEmpty)
        XCTAssertTrue(model.episodes.first(where: { $0.id == episode.id })?.preparationState.isRunning == true)
        try await Task.sleep(for: .milliseconds(10))
    }

    /// David hit a queued episode and had to press Stop and then Prepare to run
    /// it. That workaround is worse than it looks: cancelling drops the stored
    /// policy snapshot, so the job came back under whatever Settings said at
    /// the time rather than what it was admitted with.
    func testAQueuedOffPeakJobCanBeRunWithoutCancellingIt() async throws {
        let (directory, model, episode) = try automationFixture("off-peak-prepare-now")
        defer { try? FileManager.default.removeItem(at: directory) }
        model.setAutomationSettings(WiltedAutomationSettings(
            refreshPolicy: .manual, downloadPolicy: .manual,
            processingPolicy: .offPeak(try offPeakWindow()),
            transcriptPolicy: .alwaysTranscribe, removeAds: false
        ))

        model.admitAutomaticPreparation(for: episode, at: try localDate(hour: 12))
        let admitted = try XCTUnwrap(model.deferredAutomaticPreparations.first)
        XCTAssertTrue(model.isDeferredToOffPeak(episode.id),
                      "a row waiting on the clock is the one that can be started early")

        // Changing Settings afterwards must not decide anything here: this runs
        // the admitted job, not a fresh one.
        model.setAutomationSettings(WiltedAutomationSettings(
            refreshPolicy: .manual, downloadPolicy: .manual, processingPolicy: .manual,
            transcriptPolicy: .noLocalSTT, removeAds: true
        ))
        XCTAssertEqual(model.deferredAutomaticPreparations, [admitted],
                       "the snapshot is still the admitted one when the button is pressed")

        model.prepareDeferredPreparationNow(episode.id)

        XCTAssertTrue(model.episodes.first(where: { $0.id == episode.id })?.preparationState.isRunning == true,
                      "the queued job runs instead of waiting for the window")
        XCTAssertTrue(model.deferredAutomaticPreparations.isEmpty, "and is no longer deferred")
        XCTAssertTrue(model.preparationQueue.isEmpty, "and has left the visible queue")
        XCTAssertFalse(model.isDeferredToOffPeak(episode.id))
        try await Task.sleep(for: .milliseconds(10))
    }

    /// The button is offered only for the off-peak case. A row queued behind the
    /// single-run admission gate says "Queued" too, and starting it early would
    /// run two preparations at once, which is what the gate is for.
    func testARowThatIsNotWaitingOnTheClockIsNotOfferedTheButton() throws {
        let (directory, model, episode) = try automationFixture("off-peak-not-offered")
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertFalse(model.isDeferredToOffPeak(episode.id),
                       "nothing is deferred before anything is admitted")

        model.prepareDeferredPreparationNow(episode.id)
        XCTAssertEqual(model.episodes.first(where: { $0.id == episode.id })?.preparationState, .notPrepared,
                       "asking to run a job that was never deferred does nothing")
    }

    /// Walkthrough frame 6.4 -- an episode started while an article is playing --
    /// has never captured successfully. This is the model half of that path,
    /// held down so a future failure can be attributed to the view or the
    /// capture harness rather than re-argued from scratch.
    func testStartingAnEpisodeWhileAnArticlePlaysSwitchesCleanly() async throws {
        let directory = temporaryDirectory("article-to-episode")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-playing", "--wilted-ui-fixture-podcasts", "--wilted-ui-fixture-prepared"],
            stateDirectoryOverride: directory,
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        try await settle(model)
        XCTAssertNotNil(model.selectedArticleID, "the fixture starts with an article playing")

        let episode = try XCTUnwrap(model.episodes.first)
        model.playEpisode(episode)
        await model.waitForPlaybackOperationForTesting()
        try await settle(model)

        XCTAssertEqual(model.currentEpisode?.id, episode.id,
                       "the episode takes over, which is what puts Notes in the rail")
        XCTAssertNil(model.selectedArticleID, "and the article lets go")
        XCTAssertNil(model.playbackError)
        XCTAssertNil(model.playbackOperationStatus, "a rail left spinning never goes idle for XCUITest")
    }

    func testOnlyNoLocalSpeechToTextWithRemovalOnBlocksAdRemoval() throws {
        // The pane offers the two controls side by side, so every pair a reader
        // can reach is checked, not only the one that fails.
        for policy in [WiltedAutomationTranscriptPolicy.bestAvailable, .alwaysTranscribe, .noLocalSTT] {
            for removeAds in [true, false] {
                let settings = WiltedAutomationSettings(
                    refreshPolicy: .manual, downloadPolicy: .manual, processingPolicy: .immediate,
                    transcriptPolicy: policy, removeAds: removeAds
                )
                let blocked = policy == .noLocalSTT && removeAds
                XCTAssertEqual(settings.transcriptPolicyBlocksAdRemoval, blocked,
                               "\(policy.settingsControlLabel) with removeAds \(removeAds)")
            }
        }
    }

    func testTheBlockedAdRemovalExplanationNamesTheCauseAndBothWaysOut() throws {
        let explanation = WiltedAutomationSettings.transcriptPolicyBlocksAdRemovalExplanation

        // Naming one control would leave a reader looking at the other one
        // wondering which of them is wrong.
        XCTAssertTrue(explanation.contains("Remove ads"), explanation)
        XCTAssertTrue(explanation.contains(WiltedAutomationTranscriptPolicy.noLocalSTT.settingsControlLabel),
                      explanation)
        XCTAssertTrue(explanation.contains("no episode will prepare"), explanation)
    }

    func testABlockedConfigurationStillDecodesAndSurvivesRelaunch() throws {
        // Removal once ran from a publisher's cues, so this pair is a file that
        // legitimately exists. It is reported, not rejected: refusing to decode
        // it would lose every other preference saved beside it.
        let preferences = try automationSettingsPreferences()
        defer { preferences.removePersistentDomain(forName: "com.zerodelta.wilted.mac.automation-settings-tests") }
        let directory = temporaryDirectory("blocked-transcript-policy")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
        model.setAutomationSettings(WiltedAutomationSettings(
            refreshPolicy: .manual, downloadPolicy: .manual, processingPolicy: .immediate,
            transcriptPolicy: .noLocalSTT, removeAds: true
        ))

        let relaunched = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)

        XCTAssertEqual(relaunched.automationSettings.transcriptPolicy, .noLocalSTT)
        XCTAssertTrue(relaunched.automationSettings.removeAds)
        XCTAssertTrue(relaunched.automationSettings.transcriptPolicyBlocksAdRemoval)
    }

    func testPreparationPolicySnapshotMapsEveryFutureWorkerChoice() throws {
        let settings = WiltedAutomationSettings(
            refreshPolicy: .manual, downloadPolicy: .manual, processingPolicy: .offPeak(try offPeakWindow()),
            transcriptPolicy: .alwaysTranscribe, removeAds: false
        )

        let snapshot = WiltedMacModel.preparationPolicySnapshot(from: settings)

        XCTAssertEqual(snapshot.transcriptPolicy, .alwaysTranscribe)
        XCTAssertFalse(snapshot.removeAds)

        let laterSettings = WiltedAutomationSettings(
            refreshPolicy: .manual, downloadPolicy: .manual, processingPolicy: .manual,
            transcriptPolicy: .noLocalSTT, removeAds: true
        )
        XCTAssertEqual(snapshot, PodcastPreparationPolicySnapshot(
            transcriptPolicy: .alwaysTranscribe, removeAds: false
        ), "a queued job retains the snapshot captured at admission")
        XCTAssertNotEqual(snapshot, WiltedMacModel.preparationPolicySnapshot(from: laterSettings))
    }

}
