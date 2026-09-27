import CryptoKit
import Foundation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

extension WiltedMacModelTests {
    /// Hiding the window, minimising it, or closing the last one must not stop
    /// the audio. It did: the scene-phase handler called a method that paused,
    /// because one call was serving both "not frontmost" and "quitting". David
    /// found it with Cmd-H during Mac owner acceptance.
    ///
    /// The assertion has to defeat the fire-and-forget task the checkpoint runs
    /// in. Calling the method and reading the flag immediately passes against
    /// the *old* code too, because the pause has not landed yet.
    func testHidingTheWindowCheckpointsWithoutStoppingTheAudio() async throws {
        let model = try await playingModel("background-keeps-playing")
        let before = try XCTUnwrap(model.playbackCheckpointStateForTesting())
        XCTAssertTrue(before.isPlaying, "the fixture has to be playing for this to prove anything")

        model.checkpointForBackground()
        await model.waitForPlaybackOperationForTesting()
        try await settle(model)

        let after = try XCTUnwrap(model.playbackCheckpointStateForTesting())
        XCTAssertTrue(after.isPlaying, "hiding the app must not stop the episode")
        XCTAssertGreaterThan(after.sequence, before.sequence,
                             "and it still has to write the playhead down")
        model.togglePlayback()
    }

    /// The other half of the split. Termination is the one moment stopping is
    /// right: a Now Playing entry that still claims to be playing outlives the
    /// process, which is the failure `WiltedMacApp.init` records against test
    /// runs that left the machine's media keys pointed at a dead process.
    func testQuittingStopsTheAudioAndCheckpoints() async throws {
        let model = try await playingModel("quit-stops-playing")
        let before = try XCTUnwrap(model.playbackCheckpointStateForTesting())
        XCTAssertTrue(before.isPlaying)

        model.pauseForQuit()
        await model.waitForPlaybackOperationForTesting()
        try await settle(model)

        let after = try XCTUnwrap(model.playbackCheckpointStateForTesting())
        XCTAssertFalse(after.isPlaying, "quitting stops the audio")
        XCTAssertGreaterThan(after.sequence, before.sequence, "and writes the playhead down")
    }

    /// A bootstrapped model with one ready episode already playing.
    private func playingModel(_ name: String) async throws -> WiltedMacModel {
        let directory = temporaryDirectory(name)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let feedURL = try XCTUnwrap(URL(string: "https://example.test/\(name).xml"))
        let enclosureURL = try XCTUnwrap(URL(string: "https://example.test/\(name).mp3"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let episodeID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "\(name)-1", enclosureURL: enclosureURL
        )
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))

        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Lifecycle", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await Self.addReadyEpisode(
                    episodeID, guid: "\(name)-1", feedID: feedID, feedURL: feedURL,
                    enclosureURL: enclosureURL, publishedAt: created.date,
                    directory: directory, store: store, created: created
                )
                return store
            }, preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let episode = try XCTUnwrap(model.episodes.first)
        model.playEpisode(episode)
        try await settle(model)
        return model
    }

    /// The scheduling timestamp is the only thing standing between an interval
    /// policy and repeating its work on every tick, so it has to outlive the
    /// process. It lives in preferences rather than the store because losing it
    /// costs one extra idempotent refresh; claims, which cannot be
    /// reconstructed, live in the store.
    func testTheLastAutomaticRefreshTimeSurvivesRelaunch() throws {
        let preferences = try automationSettingsPreferences()
        defer { preferences.removePersistentDomain(forName: "com.zerodelta.wilted.mac.automation-settings-tests") }
        let directory = temporaryDirectory("automation-last-refresh")
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
        XCTAssertNil(model.lastAutomationRefreshAt, "a first launch has nothing to space itself from")

        let refreshedAt = Date(timeIntervalSince1970: 1_700_000_000)
        preferences.set(refreshedAt, forKey: WiltedMacModel.lastAutomationRefreshPreferenceKey)
        let relaunched = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
        XCTAssertEqual(relaunched.lastAutomationRefreshAt, refreshedAt)

        // An interval that has not elapsed since that time must not fire again.
        let settings = WiltedAutomationSettings(
            refreshPolicy: .whileOpen(everyHours: 12), downloadPolicy: .newestOnePerEnabledFeed,
            processingPolicy: .immediate, transcriptPolicy: .bestAvailable,
            removeAds: true
        )
        let tooSoon = WiltedAutomationCoordinator.plan(
            settings: settings, trigger: .openWindowTick,
            lastRefreshSuccess: relaunched.lastAutomationRefreshAt,
            now: refreshedAt.addingTimeInterval(11 * 3_600)
        )
        XCTAssertFalse(tooSoon.shouldRefresh)
    }

    func testAutomationSettingsRoundTripThroughInjectedPreferences() throws {
        let preferences = try automationSettingsPreferences()
        defer { preferences.removePersistentDomain(forName: "com.zerodelta.wilted.mac.automation-settings-tests") }
        let directory = temporaryDirectory("automation-round-trip")
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = WiltedAutomationSettings(
            refreshPolicy: .whileOpen(everyHours: 12),
            downloadPolicy: .newestThreePerEnabledFeed,
            processingPolicy: .offPeak(try offPeakWindow()),
            transcriptPolicy: .alwaysTranscribe,
            removeAds: false
        )

        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
        model.setAutomationSettings(settings)

        XCTAssertEqual(model.automationSettings, settings)
        XCTAssertNotNil(preferences.data(forKey: WiltedMacModel.automationSettingsPreferenceKey))
        XCTAssertEqual(WiltedAutomationDownloadPolicy.allNewlyAdmittedUpToTwenty.maximumEpisodesPerRefresh, 20)
    }

    func testLegacyReadableTranscriptSettingDecodesButIsNotReencoded() throws {
        let payload = #"{"version":1,"refreshPolicy":{"kind":"manual"},"downloadPolicy":"manual","processingPolicy":{"kind":"immediate"},"transcriptPolicy":"bestAvailable","removeAds":true,"readableTranscriptPass":false}"#

        let settings = try JSONDecoder().decode(WiltedAutomationSettings.self, from: Data(payload.utf8))
        XCTAssertEqual(settings, .defaults)

        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any]
        XCTAssertNil(encoded?["readableTranscriptPass"])
    }

    func testSettingsSavedBeforeTheMenuFilledItselfDecodeWithItEnabled() throws {
        let payload = #"{"version":1,"refreshPolicy":{"kind":"manual"},"downloadPolicy":"manual","processingPolicy":{"kind":"immediate"},"transcriptPolicy":"bestAvailable","removeAds":true}"#

        let settings = try JSONDecoder().decode(WiltedAutomationSettings.self, from: Data(payload.utf8))
        XCTAssertTrue(settings.autoAddPreparedToMenu,
                      "a file that predates the preference must not read as a refusal")
        XCTAssertEqual(settings, .defaults)

        let encoded = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(settings)) as? [String: Any]
        XCTAssertEqual(encoded?["autoAddPreparedToMenu"] as? Bool, true,
                       "the preference is written back once it has been read")
    }

    func testTurningTheMenuOffIsKeptAcrossASaveAndLoad() throws {
        let settings = WiltedAutomationSettings(
            refreshPolicy: .manual, downloadPolicy: .manual, processingPolicy: .immediate,
            transcriptPolicy: .bestAvailable, removeAds: true, autoAddPreparedToMenu: false
        )
        let restored = try JSONDecoder().decode(
            WiltedAutomationSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertFalse(restored.autoAddPreparedToMenu)
        XCTAssertEqual(restored, settings)
    }

    func testOnlyEpisodesThatBecamePreparedOnThisReloadCountAsMenuArrivals() {
        func episode(_ id: String, prepared: Bool) -> WiltedMacEpisode {
            WiltedMacEpisode(
                id: id, title: id, feedTitle: "Fixtures", summary: "Fixture", artworkURL: nil,
                releasedAt: Date(timeIntervalSince1970: 1_700_000_000), durationSeconds: 600,
                playbackSeconds: 0, downloadState: .completed,
                preparationState: prepared ? .prepared(summary: "Ready") : .notPrepared
            )
        }
        let loaded = [
            episode("just-finished", prepared: true),
            episode("prepared-all-along", prepared: true),
            episode("first-load", prepared: true),
            episode("still-waiting", prepared: false)
        ]

        let arrivals = WiltedMacModel.episodeIDsNewlyPrepared(
            in: loaded,
            preparedBefore: ["prepared-all-along"],
            knownBefore: ["just-finished", "prepared-all-along", "still-waiting"]
        )

        XCTAssertEqual(arrivals, ["just-finished"],
                       "an episode this process has never seen is a first load, not an arrival, "
                       + "or opening the app would empty the Larder into the Menu")
    }

    func testEveryAutomationControlValueMapsAndPersists() throws {
        let preferences = try automationSettingsPreferences()
        defer { preferences.removePersistentDomain(forName: "com.zerodelta.wilted.mac.automation-settings-tests") }
        let directory = temporaryDirectory("automation-control-values")
        defer { try? FileManager.default.removeItem(at: directory) }
        let window = try offPeakWindow()

        let refreshPolicies: [WiltedAutomationRefreshPolicy] = [
            .manual, .onLaunch, .whileOpen(everyHours: 6),
            .whileOpen(everyHours: 12), .whileOpen(everyHours: 24)
        ]
        let downloadPolicies: [WiltedAutomationDownloadPolicy] = [
            .manual, .newestOnePerEnabledFeed, .newestThreePerEnabledFeed, .allNewlyAdmittedUpToTwenty
        ]
        let processingPolicies: [WiltedAutomationProcessingPolicy] = [.immediate, .manual, .offPeak(window)]
        let transcriptPolicies: [WiltedAutomationTranscriptPolicy] = [.bestAvailable, .alwaysTranscribe, .noLocalSTT]

        XCTAssertEqual(Set(refreshPolicies.map(\.settingsControlLabel)).count, refreshPolicies.count)
        XCTAssertEqual(Set(downloadPolicies.map(\.settingsControlLabel)).count, downloadPolicies.count)
        XCTAssertEqual(Set(processingPolicies.map(\.settingsControlLabel)).count, processingPolicies.count)
        XCTAssertEqual(Set(transcriptPolicies.map(\.settingsControlLabel)).count, transcriptPolicies.count)
        for policy in refreshPolicies {
            XCTAssertEqual(WiltedAutomationRefreshPolicy.fromSettingsControlLabel(policy.settingsControlLabel), policy)
        }
        for policy in downloadPolicies {
            XCTAssertEqual(WiltedAutomationDownloadPolicy.fromSettingsControlLabel(policy.settingsControlLabel), policy)
        }
        for policy in processingPolicies {
            XCTAssertEqual(
                WiltedAutomationProcessingPolicy.fromSettingsControlLabel(policy.settingsControlLabel, window: window),
                policy
            )
        }
        for policy in transcriptPolicies {
            XCTAssertEqual(WiltedAutomationTranscriptPolicy.fromSettingsControlLabel(policy.settingsControlLabel), policy)
        }

        let settings = refreshPolicies.map {
            WiltedAutomationSettings(
                refreshPolicy: $0, downloadPolicy: .manual, processingPolicy: .immediate,
                transcriptPolicy: .bestAvailable, removeAds: true
            )
        } + downloadPolicies.map {
            WiltedAutomationSettings(
                refreshPolicy: .manual, downloadPolicy: $0, processingPolicy: .immediate,
                transcriptPolicy: .bestAvailable, removeAds: true
            )
        } + processingPolicies.map {
            WiltedAutomationSettings(
                refreshPolicy: .manual, downloadPolicy: .manual, processingPolicy: $0,
                transcriptPolicy: .bestAvailable, removeAds: true
            )
        } + transcriptPolicies.map {
            WiltedAutomationSettings(
                refreshPolicy: .manual, downloadPolicy: .manual, processingPolicy: .immediate,
                transcriptPolicy: $0, removeAds: true
            )
        }

        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
        for candidate in settings {
            model.setAutomationSettings(candidate)
            let relaunched = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
            XCTAssertEqual(relaunched.automationSettings, candidate)
        }
    }

    func testAutomationStatusOnlyOffersStopWhileWorkCanBeInterrupted() {
        XCTAssertFalse(WiltedAutomationStatus.idle.isCancellable)
        XCTAssertFalse(WiltedAutomationStatus.failed("Network unavailable").isCancellable)
        XCTAssertFalse(WiltedAutomationStatus.cancelled.isCancellable)
        XCTAssertFalse(WiltedAutomationStatus.finished(refreshed: 2, downloaded: 1).isCancellable)
        XCTAssertTrue(WiltedAutomationStatus.refreshing(feedsRemaining: 2).isCancellable)
        XCTAssertTrue(WiltedAutomationStatus.downloading(episode: "Daily Brief", remaining: 1).isCancellable)
        XCTAssertTrue(WiltedAutomationStatus.retrying(afterSeconds: 30, attempt: 2).isCancellable)
        XCTAssertEqual(
            WiltedAutomationStatus.refreshing(feedsRemaining: 1).settingsStatusText,
            "Refreshing 1 feed"
        )
        XCTAssertEqual(WiltedAutomationStatus.failed("Network unavailable").settingsStatusText,
                       "Failed: Network unavailable")
        XCTAssertEqual(WiltedAutomationStatus.cancelled.settingsStatusText, "Stopped")
        XCTAssertEqual(WiltedAutomationStatus.finished(refreshed: 2, downloaded: 1).settingsStatusText,
                       "Finished: 2 refreshed, 1 downloaded")
    }

    func testAutomationSettingsSurviveRelaunch() throws {
        let preferences = try automationSettingsPreferences()
        defer { preferences.removePersistentDomain(forName: "com.zerodelta.wilted.mac.automation-settings-tests") }
        let directory = temporaryDirectory("automation-relaunch")
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = WiltedAutomationSettings(
            refreshPolicy: .onLaunch,
            downloadPolicy: .allNewlyAdmittedUpToTwenty,
            processingPolicy: .manual,
            transcriptPolicy: .noLocalSTT,
            removeAds: false
        )

        let first = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
        first.setAutomationSettings(settings)
        let second = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)

        XCTAssertEqual(second.automationSettings, settings)
    }

    func testCorruptAutomationSettingsFallClosedToDefaults() throws {
        let preferences = try automationSettingsPreferences()
        defer { preferences.removePersistentDomain(forName: "com.zerodelta.wilted.mac.automation-settings-tests") }
        let directory = temporaryDirectory("automation-corrupt")
        defer { try? FileManager.default.removeItem(at: directory) }
        preferences.set(Data("not settings data".utf8), forKey: WiltedMacModel.automationSettingsPreferenceKey)

        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)

        XCTAssertEqual(model.automationSettings, .defaults)
    }

    func testInvalidAutomationSettingsValuesFallClosedToDefaults() throws {
        let preferences = try automationSettingsPreferences()
        defer { preferences.removePersistentDomain(forName: "com.zerodelta.wilted.mac.automation-settings-tests") }
        let directory = temporaryDirectory("automation-invalid")
        defer { try? FileManager.default.removeItem(at: directory) }
        preferences.set(WiltedMacLibraryOrder.oldest.rawValue, forKey: WiltedMacModel.libraryOrderPreferenceKey)
        preferences.set(1.5, forKey: WiltedMacModel.playbackRatePreferenceKey)
        let invalidPayloads = [
            #"{"version":1,"refreshPolicy":{"kind":"whileOpen","everyHours":7},"downloadPolicy":"manual","processingPolicy":{"kind":"immediate"},"transcriptPolicy":"bestAvailable","removeAds":true,"readableTranscriptPass":true}"#,
            #"{"version":1,"refreshPolicy":{"kind":"manual"},"downloadPolicy":"manual","processingPolicy":{"kind":"offPeak","window":{"start":{"hour":24,"minute":0},"end":{"hour":6,"minute":0}}},"transcriptPolicy":"bestAvailable","removeAds":true,"readableTranscriptPass":true}"#,
            #"{"version":2,"refreshPolicy":{"kind":"manual"},"downloadPolicy":"manual","processingPolicy":{"kind":"immediate"},"transcriptPolicy":"bestAvailable","removeAds":true,"readableTranscriptPass":true}"#
        ]

        XCTAssertNil(WiltedAutomationLocalTime(hour: 24, minute: 0))
        let time = try XCTUnwrap(WiltedAutomationLocalTime(hour: 6, minute: 0))
        XCTAssertNil(WiltedAutomationOffPeakWindow(start: time, end: time))
        for payload in invalidPayloads {
            preferences.set(Data(payload.utf8), forKey: WiltedMacModel.automationSettingsPreferenceKey)
            let model = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
            XCTAssertEqual(model.automationSettings, .defaults, "invalid persisted settings must fail closed")
            XCTAssertEqual(model.libraryOrder, .oldest)
            XCTAssertEqual(model.playbackRate, 1.5)
        }
    }

    func testAbsentAutomationSettingsUseCurrentDefaults() throws {
        let preferences = try automationSettingsPreferences()
        defer { preferences.removePersistentDomain(forName: "com.zerodelta.wilted.mac.automation-settings-tests") }
        let directory = temporaryDirectory("automation-absent")
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)

        XCTAssertEqual(model.automationSettings, .defaults)
        XCTAssertNil(preferences.data(forKey: WiltedMacModel.automationSettingsPreferenceKey))
    }

    func testAutomationSettingsDoNotDisturbLegacyPreferenceKeys() throws {
        let preferences = try automationSettingsPreferences()
        defer { preferences.removePersistentDomain(forName: "com.zerodelta.wilted.mac.automation-settings-tests") }
        let directory = temporaryDirectory("automation-legacy")
        defer { try? FileManager.default.removeItem(at: directory) }
        preferences.set(WiltedMacLibraryOrder.oldest.rawValue, forKey: WiltedMacModel.libraryOrderPreferenceKey)
        preferences.set(1.5, forKey: WiltedMacModel.playbackRatePreferenceKey)

        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
        model.setAutomationSettings(WiltedAutomationSettings(
            refreshPolicy: .whileOpen(everyHours: 6),
            downloadPolicy: .newestOnePerEnabledFeed,
            processingPolicy: .immediate,
            transcriptPolicy: .bestAvailable,
            removeAds: true
        ))
        let relaunched = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)

        XCTAssertEqual(relaunched.libraryOrder, .oldest)
        XCTAssertEqual(relaunched.playbackRate, 1.5)
        XCTAssertEqual(relaunched.automationSettings.refreshPolicy, .whileOpen(everyHours: 6))
    }

}
