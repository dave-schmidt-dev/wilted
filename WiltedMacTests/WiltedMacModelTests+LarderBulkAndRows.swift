import CryptoKit
import Foundation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

extension WiltedMacModelTests {
    // MARK: Larder bulk actions and group clears

    /// The retired upcoming-scoped clear is gone, and every group owns a clear
    /// whose identifier names the group it acts on.
    func testTheRetiredUpcomingClearIsGoneAndEveryGroupClearsItsOwnRows() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let modelSource = try WiltedMacSource.model(root: root)
        XCTAssertFalse(modelSource.contains("clearUpcomingLarder"),
                       "the upcoming-scoped clear is retired")
        let view = try WiltedMacSource.views(root: root)
        XCTAssertFalse(view.contains("wilted-larder-clear-upcoming"),
                       "the retired identifier must not survive in the view")
        for identifier in [
            "wilted-larder-clear-ready",
            "wilted-larder-clear-downloaded",
            "wilted-larder-clear-available",
        ] {
            XCTAssertTrue(view.contains(identifier), "\(identifier) must name its own group")
        }
        XCTAssertTrue(view.contains("model.larderGroupClearLabel(group)"))
    }

    func testAGroupClearRemovesExactlyItsOwnRows() {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        let available = destinationEpisode("clear-available", download: .notDownloaded, preparation: .notPrepared)
        var started = destinationEpisode("clear-started", download: .completed, preparation: .notPrepared)
        started.playbackSeconds = 30
        let untouched = destinationEpisode("clear-untouched", download: .completed, preparation: .notPrepared)
        let ready = destinationEpisode("clear-ready", download: .completed,
                                       preparation: .prepared(summary: "Ready"))
        for value in [available, started, untouched, ready] {
            model.installEpisodeForTesting(value)
            model.seedPodcastQueueMembershipForTesting(value)
        }

        model.clearLarderGroup(.downloaded)

        XCTAssertEqual(model.larderEpisodes(in: .available).map(\.id), [available.id])
        XCTAssertEqual(model.larderEpisodes(in: .playable).map(\.id), [ready.id])
        XCTAssertTrue(model.larderEpisodes(in: .downloaded).isEmpty)
        XCTAssertEqual(Set(model.larderWaitingEpisodes.map(\.id)), Set([available.id, ready.id]),
                       "only the cleared group's rows leave the Larder")
        // Nothing about the removed rows changed beyond Larder membership: no
        // download was cancelled and no prepared cut was touched.
        XCTAssertEqual(model.episodes.first { $0.id == started.id }?.downloadState, .completed)
        XCTAssertEqual(model.episodes.first { $0.id == started.id }?.preparationState, .notPrepared)
        XCTAssertEqual(model.episodes.first { $0.id == untouched.id }?.downloadState, .completed)
    }

    func testAClearLabelSaysClearWhenAnyRowWasStartedAndSkipOtherwise() {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        var started = destinationEpisode("label-started", download: .completed, preparation: .notPrepared)
        started.playbackSeconds = 12
        let fresh = destinationEpisode("label-fresh", download: .completed, preparation: .notPrepared)
        let ready = destinationEpisode("label-ready", download: .completed,
                                       preparation: .prepared(summary: "Ready"))
        for value in [started, fresh, ready] {
            model.installEpisodeForTesting(value)
            model.seedPodcastQueueMembershipForTesting(value)
        }

        XCTAssertEqual(model.larderGroupClearLabel(.downloaded), "Remove all 2 from Larder")
        XCTAssertEqual(model.larderGroupClearLabel(.playable), "Remove all 1 from Larder")
    }

    func testAGroupRemovalDoesNotMarkStartedRowsCompletedOrSkipped() throws {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        var started = destinationEpisode("report-started", download: .completed, preparation: .notPrepared)
        started.playbackSeconds = 12
        let fresh = destinationEpisode("report-fresh", download: .completed, preparation: .notPrepared)
        for value in [started, fresh] {
            model.installEpisodeForTesting(value)
            model.seedPodcastQueueMembershipForTesting(value)
        }

        model.clearLarderGroup(.downloaded)

        let message = try XCTUnwrap(model.podcastOperationMessage)
        XCTAssertEqual(message,
                       "Removed all 2 in Downloaded from Larder. No download, prepared cut, transcript, or listening history was touched.")
        XCTAssertFalse(model.episodes.first { $0.id == started.id }?.isPlayed == true)
        XCTAssertNil(model.undoableSkip, "a bulk clear leaves nothing single for Undo Skip")

        // The same queue-only contract applies when no row was started.
        let freshModel = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        let neverStarted = destinationEpisode("report-never", download: .completed, preparation: .notPrepared)
        freshModel.installEpisodeForTesting(neverStarted)
        freshModel.seedPodcastQueueMembershipForTesting(neverStarted)
        freshModel.clearLarderGroup(.downloaded)
        XCTAssertEqual(freshModel.podcastOperationMessage,
                       "Removed all 1 in Downloaded from Larder. No download, prepared cut, transcript, or listening history was touched.")
    }

    func testTheToolbarBulkActionsActOnTheSetTheirCountNames() throws {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        let available = destinationEpisode("bulk-available", download: .notDownloaded, preparation: .notPrepared)
        let downloaded = destinationEpisode("bulk-downloaded", download: .completed, preparation: .notPrepared)
        let preparing = destinationEpisode("bulk-preparing", download: .completed,
                                           preparation: .preparing(stage: "Preparing…"))
        let ready = destinationEpisode("bulk-ready", download: .completed,
                                       preparation: .prepared(summary: "Ready"))
        for value in [available, downloaded, preparing, ready] {
            model.installEpisodeForTesting(value)
            model.seedPodcastQueueMembershipForTesting(value)
        }

        XCTAssertEqual(model.larderDownloadableEpisodes.map(\.id), [available.id],
                       "Download all acts on the Available group")
        XCTAssertEqual(model.larderPreparableEpisodes.map(\.id), [downloaded.id],
                       "Prepare all acts on the downloaded rows that have not started preparing")

        // The label's count and the press's set are one accessor, so they
        // cannot promise different work.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let view = try WiltedMacSource.views(root: root)
        for fragment in [
            "model.larderDownloadableEpisodes.count",
            "actionable: model.larderDownloadableEpisodes",
            "inFlight: model.larderDownloadsInFlight",
            "model.larderPreparableEpisodes.count",
            "actionable: model.larderPreparableEpisodes",
            "inFlight: model.larderPreparationsInFlight",
        ] {
            XCTAssertTrue(view.contains(fragment), "\(fragment) must be the toolbar's source")
        }
        for identifier in [
            "wilted-larder-play-first",
            "wilted-larder-group-prepare-all",
            "wilted-larder-group-download-all",
        ] {
            XCTAssertTrue(view.contains(identifier), "\(identifier) must sit on its group's heading")
        }
        let modelSource = try WiltedMacSource.model(root: root)
        XCTAssertTrue(modelSource.contains("for episode in larderDownloadableEpisodes"))
        XCTAssertTrue(modelSource.contains("for episode in larderPreparableEpisodes"))
    }

    func testBulkActionsCountOnlyWorkThePressStartsAndReportWhatIsStillRunning() {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        let notDownloaded = destinationEpisode("bulk-not-downloaded", download: .notDownloaded, preparation: .notPrepared)
        let queued = destinationEpisode("bulk-queued", download: .queued, preparation: .notPrepared)
        let downloading = destinationEpisode(
            "bulk-downloading", download: .downloading(received: 10, expected: 100), preparation: .notPrepared
        )
        let failed = destinationEpisode("bulk-failed", download: .failed, preparation: .notPrepared)
        let cancelled = destinationEpisode("bulk-cancelled", download: .cancelled, preparation: .notPrepared)
        let notPrepared = destinationEpisode("bulk-not-prepared", download: .completed, preparation: .notPrepared)
        let preparing = destinationEpisode("bulk-preparing", download: .completed, preparation: .preparing(stage: "Queued"))
        let prepared = destinationEpisode("bulk-prepared", download: .completed, preparation: .prepared(summary: "Ready"))
        for episode in [notDownloaded, queued, downloading, failed, cancelled, notPrepared, preparing, prepared] {
            model.installEpisodeForTesting(episode)
            model.seedPodcastQueueMembershipForTesting(episode)
        }

        XCTAssertEqual(Set(model.larderDownloadableEpisodes.map(\.id)), Set([notDownloaded.id, failed.id, cancelled.id]))
        XCTAssertEqual(Set(model.larderDownloadsInFlight.map(\.id)), Set([queued.id, downloading.id]))
        XCTAssertEqual(Set(model.larderPreparableEpisodes.map(\.id)), Set([notPrepared.id]))
        XCTAssertEqual(Set(model.larderPreparationsInFlight.map(\.id)), Set([preparing.id]))

        XCTAssertTrue(WiltedMacEpisodeDownloadState.queued.isInFlight)
        XCTAssertTrue(WiltedMacEpisodeDownloadState.downloading(received: 0, expected: nil).isInFlight)
        XCTAssertFalse(WiltedMacEpisodeDownloadState.notDownloaded.isInFlight)
        XCTAssertFalse(WiltedMacEpisodeDownloadState.completed.isInFlight)
        XCTAssertFalse(WiltedMacEpisodeDownloadState.failed.isInFlight)
        XCTAssertFalse(WiltedMacEpisodeDownloadState.cancelled.isInFlight)
    }

    /// Prepare all starts exactly the Downloaded group's eligible rows and
    /// leaves every other group's rows in their prior state.
    func testPrepareAllStartsOnlyTheDownloadedGroupsEligibleRows() {
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"], stateDirectoryOverride: wiltedTemporaryDirectory("fixture"), preferences: WiltedMacTestPreferences.ephemeral()
        )
        let available = destinationEpisode("start-available", download: .notDownloaded, preparation: .notPrepared)
        let downloaded = destinationEpisode("start-downloaded", download: .completed, preparation: .notPrepared)
        let preparing = destinationEpisode("start-preparing", download: .completed,
                                           preparation: .preparing(stage: "Preparing…"))
        let ready = destinationEpisode("start-ready", download: .completed,
                                       preparation: .prepared(summary: "Ready"))
        for value in [available, downloaded, preparing, ready] {
            model.installEpisodeForTesting(value)
            model.seedPodcastQueueMembershipForTesting(value)
        }

        model.prepareAllDownloadedLarderEpisodes()

        XCTAssertEqual(
            Set(model.larderPreparationsInFlight.map(\.id)), Set<String>([downloaded.id, preparing.id]),
            "the pressed row joins the one already running"
        )

        XCTAssertEqual(model.episodes.first { $0.id == downloaded.id }?.preparationState,
                       .preparing(stage: WiltedMacModel.preparingStage),
                       "the eligible downloaded row starts")
        XCTAssertEqual(model.episodes.first { $0.id == preparing.id }?.preparationState,
                       .preparing(stage: "Preparing…"),
                       "an already-running preparation is not restarted")
        XCTAssertEqual(model.episodes.first { $0.id == available.id }?.preparationState, .notPrepared,
                       "an Available row is not prepared")
        XCTAssertEqual(model.episodes.first { $0.id == ready.id }?.preparationState,
                       .prepared(summary: "Ready"), "a Ready row is not touched")
    }

    func testPrepareAllNowOverridesDeferredRowsWithoutDuplicatingRunningWork() throws {
        let (directory, model, deferred) = try automationFixture("prepare-all-now-deferred")

        model.setAutomationSettings(WiltedAutomationSettings(
            refreshPolicy: .manual, downloadPolicy: .manual,
            processingPolicy: .offPeak(try offPeakWindow()),
            transcriptPolicy: .alwaysTranscribe, removeAds: false
        ))
        model.seedPodcastQueueMembershipForTesting(deferred)
        model.admitAutomaticPreparation(for: deferred, at: try localDate(hour: 12))
        XCTAssertEqual(model.larderPreparableEpisodes.map(\.id), [deferred.id])
        XCTAssertTrue(model.larderPreparationsInFlight.isEmpty, "a row waiting for off-peak is not running")

        model.prepareAllDownloadedLarderEpisodes()

        XCTAssertFalse(model.isDeferredForOffPeak(deferred.id))
        XCTAssertTrue(model.episodes.first(where: { $0.id == deferred.id })?.preparationState.isRunning == true)
        XCTAssertTrue(model.larderPreparableEpisodes.isEmpty,
                      "a genuinely running preparation must not be offered or started twice")
        XCTAssertEqual(model.larderPreparationsInFlight.map(\.id), [deferred.id])
    }

    // MARK: Sidebar totals

    /// The sidebar's three waiting times are the playable group's, the
    /// downloaded group's, and the whole Larder's; each is summed from the same
    /// accessor its heading counts, and an unknown duration stays a count.
    func testSidebarTotalsSumTheSameSetsTheirHeadingsCount() throws {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        func episode(_ id: String, duration: TimeInterval?, download: WiltedMacEpisodeDownloadState,
                     preparation: WiltedMacEpisodePreparationState) -> WiltedMacEpisode {
            WiltedMacEpisode(
                id: id, title: id, feedTitle: "Show", summary: "",
                artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 1_700_000_000),
                durationSeconds: duration, playbackSeconds: 0,
                downloadState: download, preparationState: preparation
            )
        }
        let readyKnown = episode("sidebar-ready-known", duration: 600, download: .completed,
                                 preparation: .prepared(summary: "Ready"))
        let readyUnknown = episode("sidebar-ready-unknown", duration: nil, download: .completed,
                                   preparation: .prepared(summary: "Ready"))
        let downloaded = episode("sidebar-downloaded", duration: 300, download: .completed,
                                 preparation: .notPrepared)
        for value in [readyKnown, readyUnknown, downloaded] {
            model.installEpisodeForTesting(value)
            model.seedPodcastQueueMembershipForTesting(value)
        }

        XCTAssertEqual(model.larderGroupAudioSummary(.playable).seconds, 600)
        XCTAssertEqual(model.larderGroupAudioSummary(.playable).unknownCount, 1,
                       "an unknown duration is excluded and counted, not treated as zero")
        XCTAssertEqual(model.larderGroupAudioSummary(.downloaded).seconds, 300)
        XCTAssertEqual(model.larderGroupAudioSummary(.downloaded).unknownCount, 0)
        XCTAssertEqual(model.larderAudioSummary.seconds, 900)
        XCTAssertEqual(model.larderAudioSummary.unknownCount, 1)
        XCTAssertEqual(model.larderAudioSummary, WiltedMacQueueAudioSummary(episodes: model.larderWaitingEpisodes),
                       "the whole-Larder figure sums the waiting set the Larder counts")

        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let view = try WiltedMacSource.views(root: root)
        for fragment in [
            "wilted-sidebar-ready-total",
            "wilted-sidebar-downloaded-total",
            "wilted-sidebar-larder-total",
            "model.larderGroupAudioSummary(.playable)",
            "model.larderGroupAudioSummary(.downloaded)",
            "model.larderAudioSummary",
        ] {
            XCTAssertTrue(view.contains(fragment), "\(fragment) must be in the sidebar's totals")
        }
        // The totals are a standing readout, so they sit below the navigation
        // List rather than inside it, where a growing destination list would
        // scroll them out of sight.
        let listEnd = try XCTUnwrap(view.range(of: ".scrollContentBackground(.hidden)"))
        let totals = try XCTUnwrap(view.range(of: "if mode == .full { totals }"))
        XCTAssertTrue(totals.lowerBound > listEnd.upperBound,
                      "the totals must be pinned below the navigation List, not scroll with it")
        XCTAssertTrue(view.contains("wilted-sidebar-totals"))
    }

    // MARK: Larder row controls

    /// A preparing row offers Stop and a failed preparation offers Retry, both
    /// on the row that is in the state.
    func testAPreparingRowOffersStopAndAFailedOneOffersRetry() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let view = try WiltedMacSource.views(root: root)
        XCTAssertTrue(view.contains("wilted-larder-stop-"),
                      "a preparing row must offer a way to stop the run")
        XCTAssertTrue(view.contains("model.cancelEpisodePreparation(episode)"))
        XCTAssertTrue(view.contains("wilted-larder-retry-"),
                      "a failed preparation must offer a retry beside it")
        XCTAssertTrue(view.contains("model.prepareEpisode(episode)"))
        XCTAssertTrue(view.contains("episode.preparationState.isRunning"))
        XCTAssertTrue(view.contains("case .failed = episode.preparationState"))
    }

    // MARK: Larder row completion

    /// A Larder row exposes explicit completion only after it has started and
    /// before the durable listening record exists.
    func testLarderRowCompletionEligibilityUsesStartedAndDurablePlayedState() {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        let started = retirementEpisode("retire-started", position: 12)
        let unstarted = retirementEpisode("retire-unstarted", position: 0)
        var played = retirementEpisode("retire-played", position: 99)
        played.isPlayed = true
        model.installEpisodeForTesting(started)
        model.installEpisodeForTesting(unstarted)
        model.installEpisodeForTesting(played)

        XCTAssertTrue(model.hasStartedEpisode(started))
        XCTAssertFalse(model.hasStartedEpisode(unstarted))
        XCTAssertTrue(model.hasStartedEpisode(played))
        XCTAssertTrue(played.isPlayed, "a durable record suppresses duplicate completion iconography")

        let playing = retirementEpisode("retire-playing", position: 0)
        model.installEpisodeForTesting(playing)
        model.installPlaybackStateForTesting(episode: playing, isPlaying: true, position: 0, duration: 600)
        XCTAssertTrue(model.hasStartedEpisode(playing),
                      "the episode playing right now counts as started")
    }

    private func retirementEpisode(_ id: String, position: TimeInterval) -> WiltedMacEpisode {
        WiltedMacEpisode(
            id: id, title: id, feedTitle: "Show", summary: "",
            artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationSeconds: 600, playbackSeconds: position,
            downloadState: .completed, preparationState: .notPrepared
        )
    }

    /// The started predicate is declared once in the model, while the view
    /// uses the durable Played flag to avoid a duplicate completion control.
    func testTheCompletionControlUsesModelStartedAndPlayedState() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let modelSource = try WiltedMacSource.model(root: root)
        XCTAssertEqual(modelSource.components(separatedBy: "playbackSeconds > 0").count - 1, 1,
                       "the started predicate must have one home")
        let view = try WiltedMacSource.views(root: root)
        XCTAssertEqual(view.components(separatedBy: "playbackSeconds > 0").count - 1, 0,
                       "the view must not restate the predicate")
        XCTAssertTrue(view.contains("model.hasStartedEpisode(episode) && !episode.isPlayed"))
        XCTAssertTrue(view.contains("model.skipEpisode(episode)"))
        XCTAssertTrue(view.contains("wilted-larder-mark-completed-\\(episode.id)"))
        XCTAssertTrue(view.contains("Remove from Larder"),
                      "an anomalous played row still has an explicit retirement path")
        XCTAssertFalse(modelSource.contains("larderRowRetirementLabel"))
        XCTAssertFalse(view.contains("replacingOccurrences(of: \"could not be skipped\""),
                       "the view must present the model's completion message verbatim")
        XCTAssertTrue(modelSource.contains("Marked \\(episode.title) completed. Undo completion restores it."))
        XCTAssertTrue(modelSource.contains("could not be marked completed."))
        XCTAssertEqual(view.components(separatedBy: "model.removeEpisode(").count - 1, 0,
                       "the destructive path gets no row surface")
    }

}
