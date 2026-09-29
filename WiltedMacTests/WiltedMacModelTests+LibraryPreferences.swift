import CryptoKit
import Foundation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

extension WiltedMacModelTests {
    // MARK: Library preferences

    func testLarderSortIsTheOnlyOrderPreference() throws {
        // A fixed suite: `removePersistentDomain` empties the file but leaves
        // it, so a per-run name would litter ~/Library/Preferences.
        let suite = "com.zerodelta.wilted.mac.model-order-tests"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        preferences.removePersistentDomain(forName: suite)
        defer { preferences.removePersistentDomain(forName: suite) }
        let directory = temporaryDirectory("order")


        let first = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
        XCTAssertEqual(first.larderSort, .newest, "a fresh install lists newest first")
        // The retired `libraryOrder` view writes the Larder's own sort, so the
        // Menu bulk order and auto-advance can no longer disagree with what
        // the shelf shows.
        first.libraryOrder = .oldest
        XCTAssertEqual(first.larderSort, .oldest, "the legacy view and the Larder are one preference")
        first.larderSort = .title

        let second = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
        XCTAssertEqual(second.larderSort, .title, "the choice must outlive the model that made it")
        XCTAssertEqual(second.libraryOrder, .newest, "a non-date sort reads as its newest projection")
    }

    func testStoredLegacyLibraryOrderMigratesForward() throws {
        let suite = "com.zerodelta.wilted.mac.model-order-migration-tests"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        preferences.removePersistentDomain(forName: suite)
        defer { preferences.removePersistentDomain(forName: suite) }
        let directory = temporaryDirectory("order-migration")

        preferences.set(WiltedMacLibraryOrder.oldest.rawValue, forKey: WiltedMacModel.libraryOrderPreferenceKey)

        let migrated = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
        XCTAssertEqual(migrated.larderSort, .oldest,
                       "a host that only ever stored the retired key keeps its oldest-first shelf")
        XCTAssertEqual(
            preferences.string(forKey: WiltedMacModel.larderSortPreferenceKey),
            WiltedMacLarderSort.oldest.rawValue,
            "the migration writes the choice forward under the surviving key"
        )

        preferences.set(WiltedMacLarderSort.title.rawValue, forKey: WiltedMacModel.larderSortPreferenceKey)
        preferences.set(WiltedMacLibraryOrder.oldest.rawValue, forKey: WiltedMacModel.libraryOrderPreferenceKey)
        let again = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
        XCTAssertEqual(again.larderSort, .title, "a surviving sort wins over the retired key")
    }

    /// 2.7: only `menuSort` orders the Menu. The Feeds sort and the retired
    /// projection can change without moving a single Menu row.
    func testMenuOrderReadsOnlyMenuSortNotTheFeedsSort() {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        func ready(_ id: String, title: String) -> WiltedMacEpisode {
            WiltedMacEpisode(
                id: id, title: title, feedTitle: "Show", summary: "",
                artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 1_700_000_000),
                durationSeconds: 600, playbackSeconds: 0, downloadState: .completed,
                preparationState: .prepared(summary: "Ready")
            )
        }
        let zulu = ready("order-zulu", title: "Zulu")
        let alpha = ready("order-alpha", title: "Alpha")
        for value in [zulu, alpha] {
            model.installEpisodeForTesting(value)
            model.seedPodcastQueueMembershipForTesting(value)
        }
        model.menuSort = .title
        let before = model.menuDisplayEpisodeIDs
        XCTAssertEqual(before, [alpha.id, zulu.id])

        model.larderSort = .oldest
        model.libraryOrder = .oldest

        XCTAssertEqual(model.menuDisplayEpisodeIDs, before,
                       "the Feeds sort and the retired projection do not order the Menu")
        XCTAssertEqual(model.larderSort, .oldest, "the two legacy spellings stay one preference")
        XCTAssertEqual(model.libraryOrder, .oldest)
    }

    func testMenuAudioSummariesCountKnownDurationsAndExposeUnknowns() {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        let ready = WiltedMacEpisode(
            id: "summary-ready", title: "Ready", feedTitle: "Show", summary: "Fixture",
            artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationSeconds: 600, playbackSeconds: 0, downloadState: .completed,
            preparationState: .prepared(summary: "Ready")
        )
        let unknown = WiltedMacEpisode(
            id: "summary-unknown", title: "Unknown", feedTitle: "Show", summary: "Fixture",
            artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 1_700_000_001),
            durationSeconds: nil, playbackSeconds: 0, downloadState: .notDownloaded,
            preparationState: .notPrepared
        )
        for value in [ready, unknown] {
            model.installEpisodeForTesting(value)
            model.seedPodcastQueueMembershipForTesting(value)
        }

        // The whole-Menu total sums the waiting set; an unknown duration is
        // visible as a count rather than silently counted as zero.
        XCTAssertEqual(model.menuAudioSummary, WiltedMacQueueAudioSummary(episodes: [ready, unknown]))
        XCTAssertEqual(model.menuAudioSummary.seconds, 600)
        XCTAssertEqual(model.menuAudioSummary.unknownCount, 1)
        XCTAssertEqual(model.menuAudioSummary.detailLabel, "10m · 1 unknown")
    }

    func testTheRetiredLarderKindGroupingIsGone() {
        // Commit 4f83343's kind grouping was withdrawn with the Larder. The
        // Menu has one grouping axis -- readiness -- and a second orthogonal
        // grouping by kind must not return beside it.
        let source = try? WiltedMacSource.model(root: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent())
        XCTAssertFalse(source?.contains("WiltedMacLibraryKind") == true,
                       "the kind renderer must be deleted, not moved")
        XCTAssertFalse(source?.contains("WiltedMacQueueGrouping") == true,
                       "the queue grouping type itself is retired")
        XCTAssertFalse(source?.contains("id: .kind(") == true,
                       "no queue-section kind case may remain")
    }

    func testTheOrderingPreferencesSurviveRelaunch() {
        let suite = "com.zerodelta.wilted.mac.queue-controls-tests"
        let preferences = UserDefaults(suiteName: suite) ?? UserDefaults()
        preferences.removePersistentDomain(forName: suite)
        defer { preferences.removePersistentDomain(forName: suite) }

        let first = WiltedMacModel(arguments: [], preferences: preferences)
        first.larderSort = .title
        first.menuSort = .title
        first.menuGrouping = .date
        first.selectedNavigation = .feeds

        let second = WiltedMacModel(arguments: [], preferences: preferences)
        XCTAssertEqual(second.larderSort, .title)
        XCTAssertEqual(second.menuSort, .title)
        XCTAssertEqual(second.menuGrouping, .date)
        XCTAssertEqual(second.selectedNavigation, .feeds,
                       "the selected destination must outlive the model that chose it")
    }

    func testMenuGroupingDefaultsToStatusAndBuildsFeedDateAndStatusSections() {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func episode(
            _ id: String,
            feed: String,
            daysAgo: Int,
            download: WiltedMacEpisodeDownloadState,
            preparation: WiltedMacEpisodePreparationState = .notPrepared
        ) -> WiltedMacEpisode {
            WiltedMacEpisode(
                id: id, title: id, feedTitle: feed, summary: "", artworkURL: nil,
                releasedAt: calendar.date(byAdding: .day, value: -daysAgo, to: now)!,
                durationSeconds: 600, playbackSeconds: 0, downloadState: download,
                preparationState: preparation
            )
        }
        let ready = episode(
            "group-ready", feed: "Daily Field", daysAgo: 0, download: .completed,
            preparation: .prepared(summary: "Ready")
        )
        let downloaded = episode("group-downloaded", feed: "Quiet Season", daysAgo: 1, download: .completed)
        let available = episode("group-available", feed: "Daily Field", daysAgo: 3, download: .notDownloaded)
        for value in [ready, downloaded, available] {
            model.installEpisodeForTesting(value)
            model.seedPodcastQueueMembershipForTesting(value)
        }

        XCTAssertEqual(model.menuGrouping, .status)
        XCTAssertEqual(model.menuSections(calendar: calendar, now: now).map(\.title), [
            "Ready", "Downloaded", "Not downloaded",
        ])
        XCTAssertTrue(model.menuSections(calendar: calendar, now: now).allSatisfy { $0.statusGroup != nil })

        model.menuGrouping = .feed
        let feedSections = model.menuSections(calendar: calendar, now: now)
        XCTAssertEqual(feedSections.map(\.title), ["Daily Field", "Quiet Season"])
        XCTAssertEqual(feedSections.flatMap(\.episodes).count, 3)
        XCTAssertTrue(feedSections.allSatisfy { $0.statusGroup == nil })

        model.menuGrouping = .date
        let dateSections = model.menuSections(calendar: calendar, now: now)
        XCTAssertEqual(dateSections.prefix(2).map(\.title), ["Today", "Yesterday"])
        XCTAssertEqual(dateSections.flatMap(\.episodes).count, 3)
        XCTAssertTrue(dateSections.allSatisfy { $0.statusGroup == nil })
    }

    func testMenuSortReordersOnlyUpcomingEpisodesAndKeepsCurrentInPlace() {
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"],
            stateDirectoryOverride: wiltedTemporaryDirectory("fixture"),
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        func episode(_ id: String, title: String, length: TimeInterval, published: TimeInterval) -> WiltedMacEpisode {
            WiltedMacEpisode(
                id: id, title: title, feedTitle: "Show", summary: "Fixture", artworkURL: nil,
                releasedAt: Date(timeIntervalSince1970: published), durationSeconds: length,
                playbackSeconds: 0, downloadState: .completed,
                preparationState: .prepared(summary: "Ready · transcript synced")
            )
        }
        let current = episode("menu-sort-current", title: "Current", length: 900, published: 100)
        let long = episode("menu-sort-long", title: "Alpha", length: 1_200, published: 300)
        let short = episode("menu-sort-short", title: "Zulu", length: 120, published: 200)
        let middle = episode("menu-sort-middle", title: "Middle", length: 600, published: 400)
        model.installEpisodeForTesting(long)
        model.installEpisodeForTesting(short)
        model.installEpisodeForTesting(middle)
        model.installPlaybackStateForTesting(
            episode: current, isPlaying: true, position: 12, duration: 900,
            queue: [current.id, long.id, short.id, middle.id]
        )

        model.menuSort = .shortest
        XCTAssertEqual(model.menuDisplayEpisodeIDs, [current.id, short.id, middle.id, long.id])
        XCTAssertEqual(model.menuWaitingEpisodes.map(\.id), [short.id, middle.id, long.id],
                       "the current podcast stays in Now Playing while every other durable entry keeps its order")
        XCTAssertEqual(model.menuAudioSummary.seconds, 1_920)
        XCTAssertEqual(model.currentPodcastEpisodeID, current.id)

        model.menuSort = .title
        XCTAssertEqual(model.menuDisplayEpisodeIDs, [current.id, long.id, middle.id, short.id])
        XCTAssertEqual(model.menuWaitingEpisodes.map(\.id), [long.id, middle.id, short.id])
        XCTAssertEqual(model.currentPodcastEpisodeID, current.id)

        model.moveMenuEpisode(short.id, before: long.id)
        XCTAssertEqual(model.menuSort, .custom, "a manual move must preserve the listener's custom order")
    }

    func testPlaybackSpeedSurvivesRelaunch() throws {
        let suite = "com.zerodelta.wilted.mac.model-tests"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        preferences.removePersistentDomain(forName: suite)
        defer { preferences.removePersistentDomain(forName: suite) }
        let directory = temporaryDirectory("speed")


        let first = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
        XCTAssertEqual(first.playbackRate, 1.25, "a fresh install listens at 1.25×, the owner's default")
        first.setPlaybackRate(1.5)

        let second = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
        XCTAssertEqual(second.playbackRate, 1.5, "the chosen speed must outlive the model that chose it")

        preferences.set(9.0, forKey: WiltedMacModel.playbackRatePreferenceKey)
        let third = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
        XCTAssertEqual(third.playbackRate, 2, "a stored value outside the picker's range is clamped, not trusted")
    }

    func testFixtureLaunchesStartFromTheDefaultOrderAndLeaveNothingBehind() {
        let directory = temporaryDirectory("fixture-order")


        let fixture = WiltedMacModel(arguments: ["--wilted-ui-fixture-ready"], stateDirectoryOverride: directory, preferences: WiltedMacTestPreferences.ephemeral())
        XCTAssertEqual(fixture.libraryOrder, .newest)
        fixture.libraryOrder = .oldest

        let relaunched = WiltedMacModel(arguments: ["--wilted-ui-fixture-ready"], stateDirectoryOverride: directory, preferences: WiltedMacTestPreferences.ephemeral())
        XCTAssertEqual(relaunched.libraryOrder, .newest, "a fixture launch leaves nothing behind for the next one")
    }

}
