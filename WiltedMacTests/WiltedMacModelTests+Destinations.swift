import AppKit
import SwiftUI
import CryptoKit
import Foundation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

extension WiltedMacModelTests {
    // MARK: Phase 0 — the two-destination restructure

    func testNavigationHasExactlyTheThreeSurvivingDestinations() {
        XCTAssertEqual(WiltedMacNavigation.allCases, [.larder, .feeds, .settings])
        XCTAssertEqual(WiltedMacNavigation.allCases.map(\.title), ["Larder", "Feeds", "Settings"])
    }

    func testOnlyKeptEpisodesMayResumeDurableDownloadClaims() {
        let claims: Set<String> = ["kept", "undecided", "skipped"]
        XCTAssertEqual(
            WiltedMacModel.keptDownloadClaims(claims, queueIDs: ["kept", "another-kept"]),
            ["kept"]
        )
    }

    func testARestoredSelectionNamingARetiredDestinationResolvesToTheLarder() {
        XCTAssertEqual(WiltedMacNavigation.restored(from: "library"), .larder)
        XCTAssertEqual(WiltedMacNavigation.restored(from: "processor"), .larder)
        XCTAssertEqual(WiltedMacNavigation.restored(from: "feeds"), .feeds)
        XCTAssertEqual(WiltedMacNavigation.restored(from: "menu"), .larder)
        XCTAssertEqual(WiltedMacNavigation.restored(from: "settings"), .settings)
        XCTAssertEqual(WiltedMacNavigation.restored(from: nil), .larder,
                       "no stored selection lands on the one waiting place")
        XCTAssertEqual(WiltedMacNavigation.restored(from: "sideways"), .larder,
                       "an unreadable selection resolves rather than crashing")
    }

    func testAStoredRetiredDestinationRestoresToTheLarder() {
        let directory = temporaryDirectory("navigation-restore")
        let suite = WiltedMacTestPreferences.suiteName("navigation-restore-tests")
        let preferences = UserDefaults(suiteName: suite) ?? UserDefaults()
        preferences.removePersistentDomain(forName: suite)
        defer { preferences.removePersistentDomain(forName: suite) }

        preferences.set("library", forKey: WiltedMacModel.selectedNavigationPreferenceKey)
        let fromLibrary = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory, preferences: preferences
        )
        XCTAssertEqual(fromLibrary.selectedNavigation, .larder, "the retired Larder resolves to the Larder")

        preferences.set("processor", forKey: WiltedMacModel.selectedNavigationPreferenceKey)
        let fromProcessor = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory, preferences: preferences
        )
        XCTAssertEqual(fromProcessor.selectedNavigation, .larder, "the retired Prep resolves to the Larder")

        preferences.set("settings", forKey: WiltedMacModel.selectedNavigationPreferenceKey)
        let fromSettings = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory, preferences: preferences
        )
        XCTAssertEqual(fromSettings.selectedNavigation, .settings, "a live destination still restores")
    }

    func testTheRetiredSurfacesRetainNoRenderer() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let view = try WiltedMacSource.views(root: root)
        for retired in ["WiltedMacLibraryView", "WiltedMacProcessorView", "WiltedMacEpisodeRow",
                        "WiltedMacPreparationView", "WiltedMacQueueControls", "WiltedMacQueueSection",
                        "WiltedMacQueueGrouping", "WiltedMacLibraryKind"] {
            XCTAssertFalse(view.contains(retired), "\(retired) is a retired renderer and must be deleted")
        }
        let model = try WiltedMacSource.model(root: root)
        for retired in ["preparationQueueSections", "makeQueueSections", "WiltedMacQueueSection",
                        "WiltedMacLibraryKind", "WiltedMacQueueGrouping", "WiltedMacQueueStatus",
                        "WiltedMacPreparationSort"] {
            XCTAssertFalse(model.contains(retired), "\(retired) is retired model code and must be deleted")
        }
    }

    /// Destination helper: every visible episode is in Feeds until it is kept.
    func destinationEpisode(
        _ id: String,
        download: WiltedMacEpisodeDownloadState,
        preparation: WiltedMacEpisodePreparationState
    ) -> WiltedMacEpisode {
        WiltedMacEpisode(
            id: id, title: id, feedTitle: "Show", summary: "",
            artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationSeconds: 600, playbackSeconds: 0, downloadState: download,
            preparationState: preparation
        )
    }

    func testEveryEpisodeAppearsOnExactlyOneDestination() {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        let available = destinationEpisode("dest-available", download: .notDownloaded, preparation: .notPrepared)
        let downloaded = destinationEpisode("dest-downloaded", download: .completed, preparation: .notPrepared)
        let preparing = destinationEpisode("dest-preparing", download: .completed,
                                           preparation: .preparing(stage: "Preparing…"))
        let ready = destinationEpisode("dest-ready", download: .completed,
                                       preparation: .prepared(summary: "Ready"))
        for value in [available, downloaded, preparing, ready] {
            model.installEpisodeForTesting(value)
        }

        // Nothing is kept yet: every episode is in Feeds and none is waiting.
        XCTAssertEqual(Set(model.feedsEpisodes.map(\.id)),
                       Set([available.id, downloaded.id, preparing.id, ready.id]))
        XCTAssertTrue(model.larderWaitingEpisodes.isEmpty)
        XCTAssertTrue(
            Set(model.feedsEpisodes.map(\.id))
                .isDisjoint(with: Set(model.larderWaitingEpisodes.map(\.id))),
            "no episode may appear on both destinations"
        )

        // Kept: every episode is waiting, each in exactly one Larder group, and
        // none remains in Feeds.
        for value in [available, downloaded, preparing, ready] {
            model.seedPodcastQueueMembershipForTesting(value)
        }
        XCTAssertTrue(model.feedsEpisodes.isEmpty)
        XCTAssertEqual(model.larderWaitingEpisodes.count, 4)
        let grouped = WiltedMacLarderGroup.allCases.flatMap { model.larderEpisodes(in: $0) }
        XCTAssertEqual(grouped.count, 4, "each waiting episode appears in exactly one group")
        XCTAssertEqual(Set(grouped.map(\.id)), Set(model.larderWaitingEpisodes.map(\.id)))
    }

    func testAFeedsRowOffersExactlyKeepAndSkip() throws {
        XCTAssertEqual(WiltedMacFeedsAction.allCases.map(\.rawValue), ["Keep", "Skip"],
                       "Feeds asks one question; every other step belongs on the Larder")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let view = try WiltedMacSource.views(root: root)
        XCTAssertTrue(view.contains("ForEach(WiltedMacFeedsAction.allCases)"),
                      "the inbox row's buttons are that list, not a hand-kept set")
    }

    func testKeepPutsAnEpisodeOnTheLarderWithoutTouchingItsAudio() async throws {
        let directory = wiltedTemporaryDirectory("keep-preserves-audio")
        let store = try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let episodeID = try await installPreparedLarderEpisode(
            into: store, directory: directory, suffix: "keep-preserves-audio",
            durationSeconds: 600, playbackSeconds: 12
        )
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory, storeBootstrap: { _ in store },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        addTeardownBlock { await model.close() }
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        let prepared = try XCTUnwrap(model.episodes.first { $0.id == episodeID.rawValue })
        let preparationBeforeKeep = prepared.preparationState
        let audioBeforeKeep = prepared.isReadyMediaAvailable
        let loadedMediaBeforeKeep = try await store.readyRevision(for: episodeID)
        let durableMediaBeforeKeep = try XCTUnwrap(loadedMediaBeforeKeep)
        let durablePreparationBeforeKeep = try await store.preparationOutcome(
            for: episodeID, revisionID: durableMediaBeforeKeep.revision.revisionID
        )
        let durableMediaBytesBeforeKeep = try Data(contentsOf: durableMediaBeforeKeep.mediaURL)
        let loadedPlaybackBeforeKeep = try await store.playbackState(
            for: episodeID, revisionID: durableMediaBeforeKeep.revision.revisionID
        )
        let durablePlaybackBeforeKeep = try XCTUnwrap(loadedPlaybackBeforeKeep)
        let durableListeningBeforeKeep = try await store.listeningState(for: episodeID)
        XCTAssertEqual(prepared.playbackSeconds, 12)
        XCTAssertNil(durableListeningBeforeKeep)
        XCTAssertTrue(model.feedsEpisodes.contains { $0.id == prepared.id })

        model.keepEpisode(prepared)
        await waitForFeedDecisionWriters(model)

        XCTAssertTrue(model.podcastQueueIDs.contains(prepared.id), "the kept episode waits on the Larder")
        XCTAssertTrue(model.larderWaitingEpisodes.contains { $0.id == prepared.id })
        XCTAssertFalse(model.feedsEpisodes.contains { $0.id == prepared.id })
        guard let after = model.episodes.first(where: { $0.id == prepared.id }) else {
            return XCTFail("the kept row must still exist")
        }
        XCTAssertEqual(after.downloadState, .completed, "Keep must not change the download")
        XCTAssertEqual(after.preparationState, preparationBeforeKeep,
                       "Keep must not change the prepared cut")
        XCTAssertEqual(after.isReadyMediaAvailable, audioBeforeKeep, "Keep must not change the transcript's audio")
        XCTAssertEqual(after.playbackSeconds, 12, "Keep must not change the saved position")
        let loadedPlaybackAfterKeep = try await store.playbackState(
            for: episodeID, revisionID: durablePlaybackBeforeKeep.revisionID
        )
        let durablePlaybackAfterKeep = try XCTUnwrap(loadedPlaybackAfterKeep)
        let loadedMediaAfterKeep = try await store.readyRevision(for: episodeID)
        let durableMediaAfterKeep = try XCTUnwrap(loadedMediaAfterKeep)
        let durablePreparationAfterKeep = try await store.preparationOutcome(
            for: episodeID, revisionID: durableMediaAfterKeep.revision.revisionID
        )
        let durableMediaBytesAfterKeep = try Data(contentsOf: durableMediaAfterKeep.mediaURL)
        let durableListeningAfterKeep = try await store.listeningState(for: episodeID)
        XCTAssertEqual(durablePlaybackAfterKeep, durablePlaybackBeforeKeep)
        XCTAssertEqual(durableMediaAfterKeep, durableMediaBeforeKeep)
        XCTAssertEqual(durablePreparationAfterKeep, durablePreparationBeforeKeep)
        XCTAssertEqual(durableMediaBytesAfterKeep, durableMediaBytesBeforeKeep)
        XCTAssertEqual(durableListeningAfterKeep, durableListeningBeforeKeep)
    }

    func testAnEpisodeAlreadyWaitingIsNotOfferedInFeeds() {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        let episode = destinationEpisode("feeds-excluded", download: .completed, preparation: .notPrepared)
        model.installEpisodeForTesting(episode)
        XCTAssertTrue(model.feedsEpisodes.contains { $0.id == episode.id })

        model.seedPodcastQueueMembershipForTesting(episode)

        XCTAssertFalse(model.feedsEpisodes.contains { $0.id == episode.id },
                       "an episode waiting on the Larder is not a Feeds arrival")
    }

    func testLarderGroupForEachReadinessState() {
        XCTAssertEqual(
            WiltedMacModel.larderGroup(for: destinationEpisode(
                "group-available", download: .notDownloaded, preparation: .notPrepared)),
            .available
        )
        XCTAssertEqual(
            WiltedMacModel.larderGroup(for: destinationEpisode(
                "group-downloaded", download: .completed, preparation: .notPrepared)),
            .downloaded
        )
        XCTAssertEqual(
            WiltedMacModel.larderGroup(for: destinationEpisode(
                "group-failed", download: .completed, preparation: .failed("Preparation failed"))),
            .downloaded,
            "a failed preparation is still a downloaded episode needing the prepare step"
        )
        XCTAssertEqual(
            WiltedMacModel.larderGroup(for: destinationEpisode(
                "group-prepared", download: .completed, preparation: .prepared(summary: "Ready"))),
            .playable
        )
        // Prepared but its media is gone: playable is a claim about the file
        // on disk, so it stays one step away rather than offering Play.
        var missingMedia = destinationEpisode(
            "group-media-missing", download: .completed, preparation: .prepared(summary: "Ready")
        )
        missingMedia.isReadyMediaAvailable = false
        XCTAssertEqual(WiltedMacModel.larderGroup(for: missingMedia), .downloaded)
    }

    func testTheLarderGroupSequenceIsFixed() {
        XCTAssertEqual(WiltedMacLarderGroup.allCases, [.playable, .downloaded, .available],
                       "available can be downloaded, downloaded can be prepared, prepared can be played")
    }

    func testPreparingStaysInDownloadedAndTheRowCarriesTheProgressFigure() throws {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        let preparing = destinationEpisode("group-preparing", download: .completed,
                                           preparation: .preparing(stage: "Preparing…"))
        model.installEpisodeForTesting(preparing)
        model.seedPodcastQueueMembershipForTesting(preparing)

        XCTAssertEqual(WiltedMacModel.larderGroup(for: preparing), .downloaded,
                       "preparing is a state, not a group")
        XCTAssertTrue(model.larderEpisodes(in: .downloaded).contains { $0.id == preparing.id })
        XCTAssertFalse(model.larderEpisodes(in: .playable).contains { $0.id == preparing.id })

        // The row renders the one progress accessor, keyed by the episode id.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let view = try WiltedMacSource.views(root: root)
        XCTAssertTrue(view.contains("model.preparationFraction(forEpisode: episode.id)"))
        XCTAssertTrue(view.contains("ProgressView(value: fraction).frame(width: 28)"))
        XCTAssertTrue(view.contains("wilted-larder-stop-"))
        var painted: [Data] = []
        for fraction in [0.25, 0.75] {
            model.processorRuns = [WiltedMacProcessorRun(
                id: "known-progress", itemID: preparing.id, isPodcast: true, title: preparing.title,
                source: preparing.feedTitle, stage: "preparing", detail: "Preparing", fraction: fraction,
                outcome: .running, updatedAt: Date(timeIntervalSince1970: 1_700_000_000))]
            XCTAssertEqual(model.preparationFraction(forEpisode: preparing.id), fraction)
            let control = WiltedMacLarderView(model: model, paneMode: .side)
                .nextStepControl(preparing, group: .downloaded).fixedSize()
            let host = NSHostingView(rootView: control)
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.fittingSize, CGSize(width: WiltedMacLarderView.readyActionSlotWidth, height: 32))
            let bitmap = try WiltedMacHeadless.render(control.padding(24), size: CGSize(width: 112, height: 80))
            XCTAssertGreaterThan(WiltedMacHeadless.distinctColorCount(in: bitmap), 4, "the actual progress control is painted")
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            painted.append(png)
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "larder-preparing-fraction-\(fraction)"; attachment.lifetime = .keepAlways; add(attachment)
        }
        XCTAssertNotEqual(painted[0], painted[1], "changing known progress changes the actual fixed-slot pixels")
    }

    func testASelectedLarderFilterRendersExactlyThatGroup() {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        let available = destinationEpisode("filter-available", download: .notDownloaded, preparation: .notPrepared)
        let downloaded = destinationEpisode("filter-downloaded", download: .completed, preparation: .notPrepared)
        let ready = destinationEpisode("filter-ready", download: .completed,
                                       preparation: .prepared(summary: "Ready"))
        for value in [available, downloaded, ready] {
            model.installEpisodeForTesting(value)
            model.seedPodcastQueueMembershipForTesting(value)
        }

        model.larderFilter = .downloaded
        XCTAssertEqual(Set(model.larderFilteredEpisodes.map(\.id)),
                       Set(model.larderEpisodes(in: .downloaded).map(\.id)))
        XCTAssertEqual(model.larderFilteredEpisodes.map(\.id), [downloaded.id])

        model.larderFilter = nil
        XCTAssertEqual(Set(model.larderFilteredEpisodes.map(\.id)),
                       Set(model.larderWaitingEpisodes.map(\.id)),
                       "the unfiltered selection is every waiting episode")
        XCTAssertEqual(model.larderFilteredEpisodes.count, 3)
    }

    func testEveryLarderCountReadsTheGroupAccessorItLabels() throws {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        let available = destinationEpisode("count-available", download: .notDownloaded, preparation: .notPrepared)
        let downloaded = destinationEpisode("count-downloaded", download: .completed, preparation: .notPrepared)
        let preparing = destinationEpisode("count-preparing", download: .completed,
                                           preparation: .preparing(stage: "Preparing…"))
        let ready = destinationEpisode("count-ready", download: .completed,
                                       preparation: .prepared(summary: "Ready"))
        for value in [available, downloaded, preparing, ready] {
            model.installEpisodeForTesting(value)
            model.seedPodcastQueueMembershipForTesting(value)
        }

        // One group, one set: a heading's count is the size of the rows it
        // labels, and the groups partition the waiting list exactly.
        XCTAssertEqual(model.larderEpisodes(in: .available).map(\.id), [available.id])
        XCTAssertEqual(model.larderEpisodes(in: .downloaded).map(\.id).sorted(),
                       [downloaded.id, preparing.id].sorted())
        XCTAssertEqual(model.larderEpisodes(in: .playable).map(\.id), [ready.id])
        XCTAssertEqual(
            WiltedMacLarderGroup.allCases.reduce(0) { $0 + model.larderEpisodes(in: $1).count },
            model.larderWaitingEpisodes.count
        )

        // And the view draws every heading and chip from that accessor.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let view = try WiltedMacSource.views(root: root)
        XCTAssertTrue(view.contains("model.larderEpisodes(in: group).count"),
                      "a heading or chip count must come from the group accessor")
        XCTAssertFalse(view.contains("larderQueueSections"),
                       "no parallel filter may rebuild the Larder list")
    }

    func testActiveEpisodeRowReplacesIdleMetadataWithActiveStatusAndRetainsControls() throws {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        let idleEpisode = destinationEpisode("idle-ep", download: .notDownloaded, preparation: .notPrepared)
        model.installEpisodeForTesting(idleEpisode)
        model.seedPodcastQueueMembershipForTesting(idleEpisode)

        let larder = WiltedMacLarderView(model: model, paneMode: .side)
        XCTAssertFalse(larder.isActiveEpisode(idleEpisode), "idle episode is not active")

        let idleRow = larder.larderRow(idleEpisode, position: 1, count: 1, showsGroupName: false)
        let idleBitmap = try WiltedMacHeadless.render(idleRow, size: CGSize(width: 480, height: 72))
        XCTAssertGreaterThan(WiltedMacHeadless.distinctColorCount(in: idleBitmap), 4, "idle row renders successfully")

        // Active queued episode shows queued status
        var activeEpisode = destinationEpisode("active-ep", download: .queued, preparation: .notPrepared)
        model.installEpisodeForTesting(activeEpisode)
        model.seedPodcastQueueMembershipForTesting(activeEpisode)
        XCTAssertTrue(larder.isActiveEpisode(activeEpisode), "queued download is active work")
        XCTAssertEqual(larder.activeStatusLabel(for: activeEpisode), "Download queued")

        // Active downloading episode shows percent or byte count
        activeEpisode.downloadState = .downloading(received: 45, expected: 100)
        model.installEpisodeForTesting(activeEpisode)
        XCTAssertEqual(larder.activeStatusLabel(for: activeEpisode), "Downloading 45%")

        // Active preparing episode shows running processorRuns narrative
        activeEpisode.downloadState = .completed
        activeEpisode.preparationState = .preparing(stage: "Preparing…")
        model.installEpisodeForTesting(activeEpisode)
        model.processorRuns = [WiltedMacProcessorRun(
            id: "run-narrative-1", itemID: activeEpisode.id, isPodcast: true, title: activeEpisode.title,
            source: activeEpisode.feedTitle, stage: "preparing", detail: "Preparing",
            narrative: "Finding advertisements…", fraction: 0.25, outcome: .running,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )]
        XCTAssertEqual(larder.activeStatusLabel(for: activeEpisode), "Preparing · Finding advertisements…")

        let row1 = larder.larderRow(activeEpisode, position: 1, count: 1, showsGroupName: false)
        let bitmap1 = try WiltedMacHeadless.render(row1, size: CGSize(width: 480, height: 72))
        let png1 = try XCTUnwrap(bitmap1.representation(using: .png, properties: [:]))

        // Narrative change updates the rendered row pixels
        model.processorRuns = [WiltedMacProcessorRun(
            id: "run-narrative-2", itemID: activeEpisode.id, isPodcast: true, title: activeEpisode.title,
            source: activeEpisode.feedTitle, stage: "preparing", detail: "Preparing",
            narrative: "Transcribing audio…", fraction: 0.25, outcome: .running,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )]
        XCTAssertEqual(larder.activeStatusLabel(for: activeEpisode), "Preparing · Transcribing audio…")

        let row2 = larder.larderRow(activeEpisode, position: 1, count: 1, showsGroupName: false)
        let bitmap2 = try WiltedMacHeadless.render(row2, size: CGSize(width: 480, height: 72))
        let png2 = try XCTUnwrap(bitmap2.representation(using: .png, properties: [:]))
        XCTAssertNotEqual(png1, png2, "changing narrative updates the rendered row pixels")

        // Progress change updates the rendered row pixels
        model.processorRuns = [WiltedMacProcessorRun(
            id: "run-narrative-3", itemID: activeEpisode.id, isPodcast: true, title: activeEpisode.title,
            source: activeEpisode.feedTitle, stage: "preparing", detail: "Preparing",
            narrative: "Transcribing audio…", fraction: 0.85, outcome: .running,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )]
        let row3 = larder.larderRow(activeEpisode, position: 1, count: 1, showsGroupName: false)
        let bitmap3 = try WiltedMacHeadless.render(row3, size: CGSize(width: 480, height: 72))
        let png3 = try XCTUnwrap(bitmap3.representation(using: .png, properties: [:]))
        XCTAssertNotEqual(png2, png3, "changing progress fraction updates the rendered row pixels")

        // Fallback when narrative is absent
        model.processorRuns = []
        XCTAssertEqual(larder.activeStatusLabel(for: activeEpisode), "Preparing", "narrative fallback uses lifecycle presentation")

        // Source checks: active status identifier distinct from idle metadata
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let view = try WiltedMacSource.views(root: root)
        XCTAssertTrue(view.contains("wilted-larder-active-status-"), "active status identifier must be present")
        XCTAssertTrue(view.contains("wilted-larder-metadata-"), "idle metadata identifier must be present")
        XCTAssertTrue(view.contains("wilted-larder-date-"), "idle date identifier must be present")
    }

    func testModelCausalNextActionableRowAdvancesOnQueuedAndRestoresOnFailureOrCancel() throws {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        let ep1 = destinationEpisode("ep-causal-1", download: .notDownloaded, preparation: .notPrepared)
        let ep2 = destinationEpisode("ep-causal-2", download: .notDownloaded, preparation: .notPrepared)
        let ep3 = destinationEpisode("ep-causal-3", download: .notDownloaded, preparation: .notPrepared)
        for ep in [ep1, ep2, ep3] {
            model.installEpisodeForTesting(ep)
            model.seedPodcastQueueMembershipForTesting(ep)
        }

        // 1. Initial state: All three episodes are in Not downloaded; ep-causal-1 leads
        var sections = WiltedMacEpisodePresentationSections.displaySections(
            model.larderSections(), grouping: .status, statusGroups: WiltedMacLarderGroup.allCases
        )
        XCTAssertEqual(sections.map(\.title), ["Ready", "Downloaded", "Not downloaded"])
        let availableInit = try XCTUnwrap(sections.first { $0.statusGroup == .available })
        XCTAssertEqual(availableInit.items.map(\.id), ["ep-causal-1", "ep-causal-2", "ep-causal-3"])
        XCTAssertFalse(sections.contains { $0.id == "active-work" })

        // 2. Click download on ep1: queued synchronously, Active work appended, ep-causal-2 advances to top
        model.updateEpisode("ep-causal-1") { $0.downloadState = .queued }
        sections = WiltedMacEpisodePresentationSections.displaySections(
            model.larderSections(), grouping: .status, statusGroups: WiltedMacLarderGroup.allCases
        )
        XCTAssertEqual(sections.map(\.title), ["Ready", "Downloaded", "Not downloaded", "Active work"])
        let availableAfterQueued = try XCTUnwrap(sections.first { $0.statusGroup == .available })
        XCTAssertEqual(availableAfterQueued.items.map(\.id), ["ep-causal-2", "ep-causal-3"],
                       "next actionable row advances under pointer immediately")
        let activeAfterQueued = try XCTUnwrap(sections.first { $0.id == "active-work" })
        XCTAssertEqual(activeAfterQueued.items.map(\.id), ["ep-causal-1"], "in-flight item is held in Active work below")

        // 3. In-flight downloading keeps ep-causal-2 under pointer
        model.updateEpisode("ep-causal-1") { $0.downloadState = .downloading(received: 200, expected: 500) }
        sections = WiltedMacEpisodePresentationSections.displaySections(
            model.larderSections(), grouping: .status, statusGroups: WiltedMacLarderGroup.allCases
        )
        let availableDownloading = try XCTUnwrap(sections.first { $0.statusGroup == .available })
        XCTAssertEqual(availableDownloading.items.map(\.id), ["ep-causal-2", "ep-causal-3"])

        // 4. Download failure returns episode to available list and Active work drops
        model.updateEpisode("ep-causal-1") { $0.downloadState = .failed }
        sections = WiltedMacEpisodePresentationSections.displaySections(
            model.larderSections(), grouping: .status, statusGroups: WiltedMacLarderGroup.allCases
        )
        XCTAssertEqual(sections.map(\.title), ["Ready", "Downloaded", "Not downloaded"])
        XCTAssertFalse(sections.contains { $0.id == "active-work" })
        let availableFailed = try XCTUnwrap(sections.first { $0.statusGroup == .available })
        XCTAssertEqual(availableFailed.items.map(\.id), ["ep-causal-1", "ep-causal-2", "ep-causal-3"],
                       "failed download restores available rows")

        // 5. Queued then cancelled also returns episode to available list
        model.updateEpisode("ep-causal-1") { $0.downloadState = .queued }
        model.updateEpisode("ep-causal-1") { $0.downloadState = .cancelled }
        sections = WiltedMacEpisodePresentationSections.displaySections(
            model.larderSections(), grouping: .status, statusGroups: WiltedMacLarderGroup.allCases
        )
        XCTAssertEqual(sections.map(\.title), ["Ready", "Downloaded", "Not downloaded"])
        XCTAssertFalse(sections.contains { $0.id == "active-work" })
        let availableCancelled = try XCTUnwrap(sections.first { $0.statusGroup == .available })
        XCTAssertEqual(availableCancelled.items.map(\.id), ["ep-causal-1", "ep-causal-2", "ep-causal-3"],
                       "cancelled download restores available rows")
    }
}
