import AppKit
import XCTest
@testable import WiltedMac

/// Headless form of the Settings and Menu journeys that used to launch the app under XCUITest:
/// library publisher sync review, automation controls with quarantined-sync recovery, and Prepare now.
@MainActor
final class WiltedMacSettingsJourneyTests: XCTestCase {
    private let held = "Account changed. Library changes are held for review"

    /// Was `testLibraryPublisherSyncReviewAndSyncNowJourney`.
    func testLibraryPublisherSyncReviewAndSyncNowJourney() async throws {
        let model = await WiltedMacHeadless.model(
            self, ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-library-sync", "switched"])
        XCTAssertTrue(model.showsLibraryPublisherSync, "the fixture selects the publisher card, not the legacy one")
        XCTAssertEqual(model.librarySyncStatus.headline, held)
        XCTAssertFalse(model.librarySyncStatus.canSyncNow, "a held library has no Sync now")
        XCTAssertNil(model.syncLibraryNow(), "Sync now does nothing while held")
        let context = try XCTUnwrap(model.librarySyncStatus.reviewContext)
        XCTAssertTrue(context.contains("previous account"), "the dialog says why the library is held")

        // "Keep held" is an empty action, so it changes nothing; "Use reviewed account" approves.
        let settings = try WiltedMacHeadless.viewSource("WiltedMacSettingsView.swift")
        XCTAssertTrue(settings.contains("Button(WiltedMacLibrarySyncStatus.keepHeld, role: .cancel) {}"))
        XCTAssertTrue(settings.contains("Button(WiltedMacLibrarySyncStatus.approveReview) { model.reviewLibraryAccount() }"))
        XCTAssertEqual(model.librarySyncStatus.headline, held, "Keep held changes nothing")

        await model.reviewLibraryAccount().value
        XCTAssertEqual(model.librarySyncStatus.headline, "Account reviewed. 2 library changes waiting to send")
        XCTAssertNil(model.librarySyncStatus.reviewContext, "the review control goes once approved")
        XCTAssertTrue(model.librarySyncStatus.canSyncNow)

        let send = try XCTUnwrap(model.syncLibraryNow())
        XCTAssertTrue(model.librarySyncActivity.isSyncing)
        await send.value
        let headline = model.librarySyncStatus.headline
        XCTAssertTrue(headline.hasPrefix("Local changes sent at "), headline)
        XCTAssertTrue(headline.hasSuffix("Phone fetch is separate."), headline)
        XCTAssertNotEqual(
            WiltedMacLibrarySyncStatus.timeLabel(model.librarySyncActivity.lastSentAt), "Not yet this launch")

        // The card's identifiers: the legacy actions live only in the legacy card.
        let library = try XCTUnwrap(settings.range(of: "private struct WiltedMacLibrarySyncCard"))
        let libraryCard = String(settings[library.lowerBound...])
        for identifier in ["wilted-sync-scope-note", "wilted-sync-now", "wilted-sync-review-account", "wilted-sync-last-send"] {
            XCTAssertTrue(libraryCard.contains(identifier), identifier)
        }
        for identifier in ["wilted-sync-refresh", "wilted-sync-use-current-account", "wilted-sync-producer-identity"] {
            XCTAssertFalse(libraryCard.contains(identifier), "no legacy action \(identifier)")
        }
        XCTAssertFalse(settings.contains("wilted-sync-producer-identity"), "the producer-identity placeholder is gone")

        let failing = await WiltedMacHeadless.model(
            self, ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-library-sync", "failure"], suffix: "sync-failure")
        XCTAssertEqual(failing.librarySyncStatus.headline, "2 library changes waiting to send")
        try await XCTUnwrap(failing.syncLibraryNow()).value
        XCTAssertEqual(failing.librarySyncStatus.headline, "Send failed. 2 library changes kept for retry.")
        XCTAssertTrue(failing.librarySyncStatus.canSyncNow, "a failure is retried by Sync now")
    }

    /// Was `testSettingsAutomationAndSyncRecoveryJourney`.
    func testSettingsAutomationAndSyncRecoveryJourney() async throws {
        let model = await WiltedMacHeadless.model(self, ["--wilted-ui-fixture-quarantined"])
        XCTAssertEqual(model.libraryRuntimeSelection(environment: [:]).engine, .legacy,
                       "a fixture runs the legacy engine, which owns the quarantine this journey recovers")

        // Nothing is playing, and Now Playing is not a destination.
        XCTAssertFalse(model.hasCurrentPlayback)
        XCTAssertEqual(model.playbackStatusMessage, "Nothing is playing")
        XCTAssertFalse(WiltedMacNavigation.allCases.map(\.rawValue).contains("nowPlaying"))
        model.selectedNavigation = .feeds
        model.selectedNavigation = .settings

        // The rendered Settings destination, including its automation card.
        let bitmap = try WiltedMacHeadless.render(WiltedMacRootView(model: model))
        let detail = NSRect(x: 260, y: 0, width: bitmap.pixelsWide - 260, height: bitmap.pixelsHigh)
        XCTAssertGreaterThan(WiltedMacHeadless.distinctColorCount(in: bitmap, region: detail), 8,
                             "the Settings destination rendered blank")

        let settings = try WiltedMacHeadless.viewSource("WiltedMacSettingsView.swift")
        for identifier in [
            "wilted-automation-controls", "wilted-automation-refresh-policy",
            "wilted-automation-feeds-admission-policy", "wilted-automation-processing-policy",
            "wilted-automation-transcript-policy", "wilted-automation-remove-ads", "wilted-automation-status",
        ] {
            XCTAssertTrue(settings.contains(identifier), identifier)
        }
        XCTAssertFalse(settings.contains("wilted-automation-download-policy"), "downloads belong to Larder, not Settings")

        // Idle: immediate processing, no off-peak controls, nothing to stop.
        XCTAssertEqual(model.automationSettings.processingPolicy, .immediate)
        XCTAssertTrue(model.automationStatus.settingsStatusText.localizedCaseInsensitiveContains("idle"))
        XCTAssertFalse(model.automationStatus.isCancellable, "no Stop action while automation is idle")
        XCTAssertTrue(settings.contains("if model.automationStatus.isCancellable {"))

        // The off-peak controls appear only for Off-peak, and say what the window means.
        setProcessing(model, .manual)
        XCTAssertFalse(isOffPeak(model))
        let window = try XCTUnwrap(WiltedAutomationOffPeakWindow(
            start: try XCTUnwrap(WiltedAutomationLocalTime(hour: 22, minute: 0)),
            end: try XCTUnwrap(WiltedAutomationLocalTime(hour: 6, minute: 0))))
        setProcessing(model, .offPeak(window))
        XCTAssertTrue(isOffPeak(model))
        XCTAssertTrue(settings.contains("if isOffPeakProcessing {"))
        for identifier in [
            "wilted-automation-off-peak-start", "wilted-automation-off-peak-end",
            "wilted-automation-off-peak-explanation",
        ] {
            XCTAssertTrue(settings.contains(identifier), identifier)
        }
        XCTAssertTrue(settings.contains("Uses local time. The window may continue overnight."))
        let offPeakBitmap = try WiltedMacHeadless.render(WiltedMacRootView(model: model))
        XCTAssertGreaterThan(WiltedMacHeadless.distinctColorCount(in: offPeakBitmap, region: detail), 8)

        // A quarantined account offers its recovery, and using the current account ends it.
        XCTAssertFalse(model.showsLibraryPublisherSync)
        await WiltedMacHeadless.eventually("sync quarantined") { model.syncStatus.phase == .quarantined }
        XCTAssertEqual(model.syncStatus.phase.rawValue.capitalized, "Quarantined")
        XCTAssertTrue(settings.contains("if model.syncStatus.phase == .quarantined {"))
        XCTAssertTrue(settings.contains("WiltedAccountRecoveryNotice(identifier: \"wilted-sync-use-current-account\")"))

        model.resetSyncAccount()
        await WiltedMacHeadless.eventually("sync recovered") { model.syncStatus.phase == .disabled }
        XCTAssertEqual(model.syncStatus.phase.rawValue.capitalized, "Disabled")
        XCTAssertNotEqual(model.syncStatus.phase, .quarantined, "the recovery control is gone")
    }

    /// Was `testMenuOverridesAnOffPeakDeferralWithPrepareNow`: pressing Prepare now has to end the
    /// deferral, not just change copy.
    func testMenuOverridesAnOffPeakDeferralWithPrepareNow() async throws {
        let model = await WiltedMacHeadless.model(self, [
            "--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts", "--wilted-ui-fixture-deferred",
        ])
        let episode = try XCTUnwrap(model.feedsEpisodes.first)
        model.decideFeedEpisodes(.keep, episodes: [episode])
        await WiltedMacHeadless.drainDecisions(model)
        XCTAssertEqual(model.podcastQueueIDs, [episode.id])

        // The row offers Prepare now exactly while the episode is deferred.
        XCTAssertTrue(model.isDeferredForOffPeak(episode.id),
                      "a deferred episode must offer a way past its off-peak window")
        let rows = try WiltedMacHeadless.viewSource("WiltedMacMenuView+Rows.swift")
        XCTAssertTrue(rows.contains("if model.isDeferredForOffPeak(episode.id) {"))
        XCTAssertTrue(rows.contains("wilted-menu-prepare-now-\\(episode.id)"))
        XCTAssertTrue(rows.contains("model.prepareDeferredEpisodeNow(episode)"))

        let kept = try XCTUnwrap(model.episodes.first { $0.id == episode.id })
        XCTAssertTrue(model.prepareDeferredEpisodeNow(kept))
        XCTAssertFalse(model.isDeferredForOffPeak(episode.id), "pressing Prepare now left the episode deferred")
        XCTAssertNil(model.deferredAutomaticPreparations.first { $0.episodeID == episode.id })
    }

    private func setProcessing(_ model: WiltedMacModel, _ policy: WiltedAutomationProcessingPolicy) {
        model.updateAutomationSettings { settings in
            WiltedAutomationSettings(
                refreshPolicy: settings.refreshPolicy, downloadPolicy: settings.downloadPolicy,
                processingPolicy: policy, transcriptPolicy: settings.transcriptPolicy,
                removeAds: settings.removeAds, autoAddPreparedToMenu: settings.autoAddPreparedToMenu,
                downloadEverythingOnMenu: settings.downloadEverythingOnMenu,
                prepareEverythingDownloaded: settings.prepareEverythingDownloaded
            )
        }
    }

    private func isOffPeak(_ model: WiltedMacModel) -> Bool {
        if case .offPeak = model.automationSettings.processingPolicy { return true }
        return false
    }
}
