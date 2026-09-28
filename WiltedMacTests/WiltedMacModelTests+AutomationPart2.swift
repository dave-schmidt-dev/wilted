import CryptoKit
import Foundation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

extension WiltedMacModelTests {
    func testDeferredAutomaticPreparationPersistsItsAdmissionOrderWindowAndSnapshot() throws {
        let preferences = try automationSettingsPreferences()
        defer { preferences.removePersistentDomain(forName: "com.zerodelta.wilted.mac.automation-settings-tests") }
        let window = try offPeakWindow()
        let firstSnapshot = PodcastPreparationPolicySnapshot(
            transcriptPolicy: .alwaysTranscribe, removeAds: false
        )
        let secondSnapshot = PodcastPreparationPolicySnapshot(
            transcriptPolicy: .noLocalSTT, removeAds: true
        )
        let jobs = [
            WiltedMacModel.DeferredAutomaticPreparation(
                episodeID: "first", processingPolicy: .offPeak(window), policySnapshot: firstSnapshot
            ),
            WiltedMacModel.DeferredAutomaticPreparation(
                episodeID: "second", processingPolicy: .offPeak(window), policySnapshot: secondSnapshot
            )
        ]

        WiltedMacModel.persistDeferredAutomaticPreparations(jobs, to: preferences)
        let restored = WiltedMacModel.loadDeferredAutomaticPreparations(from: preferences)

        XCTAssertEqual(restored, jobs)
        XCTAssertEqual(restored.map(\.episodeID), ["first", "second"])
        XCTAssertEqual(restored.first?.policySnapshot, firstSnapshot)
        XCTAssertEqual(restored.first?.processingPolicy, .offPeak(window))
    }

    func testExplicitPreparationStartsEvenWhenAutomaticProcessingIsManual() async throws {
        let directory = temporaryDirectory("manual-preparation-policy")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts"],
            stateDirectoryOverride: directory,
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.setAutomationSettings(WiltedAutomationSettings(
            refreshPolicy: .manual, downloadPolicy: .manual, processingPolicy: .manual,
            transcriptPolicy: .bestAvailable, removeAds: true
        ))
        let episode = try XCTUnwrap(model.episodes.first)

        model.prepareEpisode(episode)
        XCTAssertTrue(
            model.episodes.first(where: { $0.id == episode.id })?.preparationState.isRunning == true,
            "the explicit action bypasses the automatic-processing policy"
        )
        try await Task.sleep(for: .milliseconds(10))

        XCTAssertEqual(
            model.episodes.first(where: { $0.id == episode.id })?.preparationState,
            .failed("No preparation worker in fixture mode")
        )
    }

    /// Automation is stall-prone by construction: it refreshes feeds and pulls
    /// audio with nobody watching. Every stage it can sit in has to be readable
    /// from the model, and stopping it has to say so rather than going quiet.
    func testAutomationStatusIsObservableAndCancellationIsAnnounced() throws {
        let preferences = try automationSettingsPreferences()
        defer { preferences.removePersistentDomain(forName: "com.zerodelta.wilted.mac.automation-settings-tests") }
        let directory = temporaryDirectory("automation-status")
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
        XCTAssertEqual(model.automationStatus, .idle)

        model.cancelAutomation()
        XCTAssertEqual(model.automationStatus, .cancelled,
                       "a stop request is a state the surface can show, not silence")
    }

    /// Automation starts from the launch path, and the shipped defaults keep it
    /// inert.
    ///
    /// Both halves matter. Without the launch wiring a persisted claim is never
    /// resumed, so "a claim survives a crash" would be true of the store and
    /// false of the product. And because the default policy is manual, a launch
    /// that reaches this point must still do nothing, which is what preserves
    /// the behaviour of every build before automation existed.
    func testLaunchStartsAutomationAndTheDefaultPolicyDoesNothing() async throws {
        let preferences = try automationSettingsPreferences()
        defer { preferences.removePersistentDomain(forName: "com.zerodelta.wilted.mac.automation-settings-tests") }
        let directory = temporaryDirectory("automation-launch")
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
        XCTAssertEqual(model.automationSettings.refreshPolicy, .manual)
        XCTAssertEqual(model.automationSettings.downloadPolicy, .manual)

        XCTAssertEqual(model.startupState, .loading(attempt: 0, step: .openingStore))
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        XCTAssertEqual(model.startupState, .ready,
                       "the launch pass is started from the ready transition, so it has to be reached")
        await model.waitForAutomation()

        XCTAssertEqual(model.automationStatus, .idle,
                       "the launch pass ran and the manual policy declined it")
        XCTAssertNil(model.lastAutomationRefreshAt,
                     "a declined pass records no refresh, so an interval policy set later starts fresh")
        model.stopAutomationTicker()
    }

    /// Hiding the app checkpoints and stops the ticker. The scene has to start
    /// it again on the way back, or a window left open past the first focus dip
    /// never ticks again for the rest of the process, which is the only case the
    /// ticker exists for.
    /// Progress is written only on a transport press or a clean quit, so the
    /// periodic tick is the only thing standing between an abrupt exit and a
    /// listener sent back to wherever they last pressed a button. Unlike the
    /// automation tick it must survive the app losing focus, because audio
    /// keeps running with the window closed and that is exactly when nothing
    /// else is checkpointing.
    func testThePlaybackCheckpointTickerOutlivesFocusLoss() async throws {
        let preferences = try automationSettingsPreferences()
        defer { preferences.removePersistentDomain(forName: "com.zerodelta.wilted.mac.automation-settings-tests") }
        let directory = temporaryDirectory("playback-checkpoint-ticker")
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
        XCTAssertFalse(model.playbackCheckpointTickerIsRunning, "nothing ticks before a store is loaded")
        model.startPlaybackCheckpointTicker()
        XCTAssertFalse(model.playbackCheckpointTickerIsRunning, "and asking early is a no-op")

        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        await model.waitForAutomation()
        XCTAssertTrue(model.playbackCheckpointTickerIsRunning, "the ready transition starts it")

        model.startPlaybackCheckpointTicker()
        XCTAssertTrue(model.playbackCheckpointTickerIsRunning, "a repeated call is harmless")

        model.checkpointForBackground()
        XCTAssertTrue(model.playbackCheckpointTickerIsRunning,
                      "hiding the app stops the automation tick, not this one")

        // With nothing loaded the tick is a no-op rather than a write of an
        // empty position over whatever the store already holds.
        await model.checkpointPlaybackIfAdvancing()

        model.stopPlaybackCheckpointTicker()
        XCTAssertFalse(model.playbackCheckpointTickerIsRunning)
    }

    /// The unit tests run inside the app bundle, so a test that plays an
    /// episode plays it out of the machine's speakers -- which is what a gate
    /// run's unexplained tone was for days. This is the guard against it
    /// returning. Starting silent is not enough on its own: the model pushes
    /// the owner's saved volume into the backend on every load, so the check
    /// that matters is that asking for full volume changes nothing.
    func testTheTestHostNeverDrivesAudioOutput() async throws {
        let preferences = try automationSettingsPreferences()
        defer { preferences.removePersistentDomain(forName: "com.zerodelta.wilted.mac.automation-settings-tests") }
        let directory = temporaryDirectory("silent-playback")
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        XCTAssertEqual(model.playbackOutputVolumeForTesting(), 0,
                       "a backend built inside the test host starts silent")
        model.setPlaybackVolume(1)
        XCTAssertEqual(model.playbackOutputVolumeForTesting(), 0,
                       "and the owner's saved volume does not bring the sound back")
    }

    func testTheOpenWindowTickerRestartsAfterBeingStopped() async throws {
        let preferences = try automationSettingsPreferences()
        defer { preferences.removePersistentDomain(forName: "com.zerodelta.wilted.mac.automation-settings-tests") }
        let directory = temporaryDirectory("automation-ticker-restart")
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
        XCTAssertFalse(model.automationTickerIsRunning, "nothing ticks before a store is loaded")
        model.startAutomationTicker()
        XCTAssertFalse(model.automationTickerIsRunning,
                       "and asking early is a no-op rather than a ticker with nothing to read")

        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        await model.waitForAutomation()
        XCTAssertTrue(model.automationTickerIsRunning, "the ready transition starts it")

        model.startAutomationTicker()
        XCTAssertTrue(model.automationTickerIsRunning, "a repeated scene callback is harmless")

        model.checkpointForBackground()
        XCTAssertFalse(model.automationTickerIsRunning, "hiding the app stops it")

        model.startAutomationTicker()
        XCTAssertTrue(model.automationTickerIsRunning, "and coming back starts it again")
        model.stopAutomationTicker()
    }

    /// `checkpointForBackground` stops the open-window tick, which used to be
    /// the only thing that re-evaluated an off-peak window opening. The
    /// ticket-drain ticker is the fix, and it has to survive exactly the call
    /// that stops the other one -- a background tick that stops the moment
    /// the window hides is not a fix at all.
    func testTheTicketDrainTickerSurvivesGoingToBackground() async throws {
        let preferences = try automationSettingsPreferences()
        defer { preferences.removePersistentDomain(forName: "com.zerodelta.wilted.mac.automation-settings-tests") }
        let directory = temporaryDirectory("ticket-drain-ticker-restart")
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
        XCTAssertFalse(model.ticketDrainTickerIsRunning, "nothing ticks before a store is loaded")
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        await model.waitForAutomation()
        XCTAssertTrue(model.ticketDrainTickerIsRunning, "the ready transition starts it")

        model.checkpointForBackground()
        XCTAssertFalse(model.automationTickerIsRunning, "the open-window tick still stops")
        XCTAssertTrue(model.ticketDrainTickerIsRunning,
                      "the drain ticker is not scene-phase-gated the way the open-window tick is")

        model.pauseForQuit()
        XCTAssertFalse(model.ticketDrainTickerIsRunning, "actual termination is the one moment stopping it is right")
    }

    func ticketDrainProgressWindow(
        now: Date, calendar: Calendar
    ) throws -> (window: WiltedAutomationOffPeakWindow, liveMinute: Int, ineligibleMinute: Int) {
        let components = calendar.dateComponents([.hour, .minute], from: now)
        let hour = try XCTUnwrap(components.hour)
        let minute = try XCTUnwrap(components.minute)
        let liveMinute = hour * 60 + minute
        let ineligibleMinute = (liveMinute + 12 * 60) % (24 * 60)
        let windowStart = (ineligibleMinute + 2) % (24 * 60)
        let start = try XCTUnwrap(WiltedAutomationLocalTime(
            hour: windowStart / 60, minute: windowStart % 60
        ))
        let end = try XCTUnwrap(WiltedAutomationLocalTime(
            hour: ineligibleMinute / 60, minute: ineligibleMinute % 60
        ))
        return (try XCTUnwrap(WiltedAutomationOffPeakWindow(start: start, end: end)),
                liveMinute, ineligibleMinute)
    }

    func testTicketDrainProgressWindowKeepsLiveTickerMinutesEligible() throws {
        let calendar = Calendar.current
        let simulatedMidnight = try localDate(hour: 0, minute: 0)
        let oldWindow = try XCTUnwrap(WiltedAutomationOffPeakWindow(
            start: try XCTUnwrap(WiltedAutomationLocalTime(hour: 0, minute: 1)),
            end: try XCTUnwrap(WiltedAutomationLocalTime(hour: 23, minute: 59))
        ))

        XCTAssertEqual(
            WiltedAutomationCoordinator.preparationPlan(
                processingPolicy: .offPeak(oldWindow), at: simulatedMidnight, calendar: calendar
            ),
            .deferUntilOffPeak,
            "the retired fixture rejects midnight"
        )

        for liveMinute in 0 ..< 24 * 60 {
            let liveDate = try localDate(hour: liveMinute / 60, minute: liveMinute % 60)
            let fixture = try ticketDrainProgressWindow(now: liveDate, calendar: calendar)
            let policy = WiltedAutomationProcessingPolicy.offPeak(fixture.window)
            XCTAssertEqual(fixture.liveMinute, liveMinute)
            XCTAssertEqual(
                WiltedAutomationCoordinator.preparationPlan(
                    processingPolicy: policy, at: liveDate, calendar: calendar
                ),
                .prepareNow,
                "live minute=\(liveMinute)"
            )
            let ineligibleDate = try localDate(
                hour: fixture.ineligibleMinute / 60,
                minute: fixture.ineligibleMinute % 60
            )
            XCTAssertEqual(
                WiltedAutomationCoordinator.preparationPlan(
                    processingPolicy: policy, at: ineligibleDate, calendar: calendar
                ),
                .deferUntilOffPeak,
                "derived gap minute=\(fixture.ineligibleMinute)"
            )
            for drift in -5 ... 5 {
                let driftedMinute = (liveMinute + drift + 24 * 60) % (24 * 60)
                XCTAssertEqual(
                    WiltedAutomationCoordinator.preparationPlan(
                        processingPolicy: policy,
                        at: try localDate(hour: driftedMinute / 60, minute: driftedMinute % 60),
                        calendar: calendar
                    ),
                    .prepareNow,
                    "a small ticker drift stays in the eligible half-day"
                )
            }
        }
    }

    /// Step 7's done-condition. `checkpointForBackground` used to leave an
    /// off-peak-deferred episode stuck: the only ticker that re-evaluated
    /// `deferredAutomaticPreparations` was the one it stops. The window here
    /// is constructed to be eligible for all but two minutes out of the day,
    /// so the deliberately-chosen admission date below (inside a dynamic
    /// two-minute gap opposite the live clock) is reliably
    /// ineligible while the live ticker's own check is eligible. The assertion
    /// remains a poll because the production ticker reads the real clock.
    func testAPendingTicketAdvancesWhileTheWindowIsNotFrontmost() async throws {
        let directory = temporaryDirectory("ticket-drain-background-progress")
        defer { try? FileManager.default.removeItem(at: directory) }
        let feedURL = try XCTUnwrap(URL(string: "https://example.test/ticket-drain.xml"))
        let enclosureURL = try XCTUnwrap(URL(string: "https://example.test/ticket-drain.mp3"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let episodeItemID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "ticket-drain-1", enclosureURL: enclosureURL
        )
        let episodeID = episodeItemID.rawValue
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let storeCapture = StoreCapture()
        let runner = BlockingPodcastPipelineRunner()

        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                await storeCapture.capture(store)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Fixtures", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await Self.addReadyEpisode(
                    episodeItemID, guid: "ticket-drain-1", feedID: feedID, feedURL: feedURL,
                    enclosureURL: enclosureURL, publishedAt: created.date,
                    directory: directory, store: store, created: created
                )
                return store
            },
            podcastPipelineRunnerFactory: { runner },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        XCTAssertEqual(model.episodes.map(\.id), [episodeID])

        let calendar = Calendar.current
        let progressWindow = try ticketDrainProgressWindow(now: Date(), calendar: calendar)
        let almostAllDay = progressWindow.window
        let reliablyIneligibleNow = try localDate(
            hour: progressWindow.ineligibleMinute / 60,
            minute: progressWindow.ineligibleMinute % 60
        )

        // Mirrors `downloadEpisode`'s own sequence: the place in line is taken
        // before admission is decided, so there is already a durable, pending
        // ticket for this episode's preparation by the time deferral happens.
        let sequence = model.registerPreparationRequest(for: episodeID)
        XCTAssertEqual(sequence, 1)

        let capturedStoreOrNil = await storeCapture.store
        let capturedStore = try XCTUnwrap(capturedStoreOrNil)
        func fetchedTicket() async throws -> WorkTicket? {
            try await capturedStore.workTicket(kind: .podcastPreparation, subjectID: episodeID)
        }
        var attempts = 0
        var pending = try await fetchedTicket()
        while attempts < 50, pending == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
            pending = try await fetchedTicket()
            attempts += 1
        }
        let priorTicket = try XCTUnwrap(pending, "the register call's ticket write must have landed")
        XCTAssertEqual(priorTicket.state, .pending)
        let priorAttemptCount = priorTicket.attemptCount

        // The stored policy travels with the deferred job from admission,
        // not read again from live settings later (`startEligibleAutomaticPreparations`'s
        // own doc comment): it has to be the near-all-day window from the
        // start, so the one `admitAutomaticPreparation` call below both defers
        // (against the deliberately-ineligible fixed date) and leaves the
        // later real-clock re-check eligible.
        model.setAutomationSettings(WiltedAutomationSettings(
            refreshPolicy: .manual, downloadPolicy: .manual,
            processingPolicy: .offPeak(almostAllDay),
            transcriptPolicy: .alwaysTranscribe, removeAds: false
        ))

        XCTAssertEqual(
            WiltedAutomationCoordinator.preparationPlan(
                processingPolicy: .offPeak(almostAllDay), at: reliablyIneligibleNow, calendar: calendar
            ),
            .deferUntilOffPeak
        )

        let episode = try XCTUnwrap(model.episodes.first(where: { $0.id == episodeID }))
        model.admitAutomaticPreparation(for: episode, at: reliablyIneligibleNow)
        XCTAssertTrue(model.isDeferredForOffPeak(episodeID), "the deliberately-ineligible date defers it")

        model.checkpointForBackground()
        XCTAssertFalse(model.automationTickerIsRunning, "the window is not frontmost")
        XCTAssertTrue(model.ticketDrainTickerIsRunning, "started automatically at bootstrap and untouched by backgrounding")

        // Bootstrap already started this ticker at its production interval;
        // restart it at a fast one so the poll below does not have to wait
        // out that real interval.
        model.stopTicketDrainTicker()
        model.startTicketDrainTicker(interval: 0.05)

        attempts = 0
        var current = try await fetchedTicket()
        while attempts < 100, (current?.attemptCount ?? priorAttemptCount) <= priorAttemptCount {
            try await Task.sleep(nanoseconds: 20_000_000)
            current = try await fetchedTicket()
            attempts += 1
        }
        let advanced = try XCTUnwrap(current)
        XCTAssertGreaterThan(advanced.attemptCount, priorAttemptCount,
                             "admission ran and the ticket's attempt count -- its progress -- advanced "
                             + "while the window was not frontmost")

        model.stopTicketDrainTicker()
        await runner.resume(throwing: CancellationError())
    }

}
