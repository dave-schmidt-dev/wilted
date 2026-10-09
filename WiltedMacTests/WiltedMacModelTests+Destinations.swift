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
        XCTAssertTrue(view.contains("wilted-larder-progress-"))
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

}
