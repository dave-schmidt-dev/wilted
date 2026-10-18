import AppKit
import SwiftUI
import WiltedDomain
import WiltedProducer
import XCTest
@testable import WiltedMac

@MainActor
final class WiltedMacEpisodeListParityTests: XCTestCase {
    private struct SortControlHarness: View {
        @State var sort: WiltedMacLarderSort
        @State var direction: WiltedMacLarderSortDirection

        init(sort: WiltedMacLarderSort, direction: WiltedMacLarderSortDirection) {
            _sort = State(initialValue: sort)
            _direction = State(initialValue: direction)
        }

        var body: some View {
            WiltedMacEpisodeListSortControls(
                label: "Parity list", identifierPrefix: "wilted-parity-test",
                sort: $sort, direction: $direction
            )
        }
    }

    private func episode() -> WiltedMacEpisode {
        WiltedMacEpisode(
            id: "parity-episode", title: "Parity episode", feedTitle: "Parity show", summary: "",
            artworkURL: nil,
            releasedAt: Date(timeIntervalSince1970: 1_900_000_000),
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sourceDurationSeconds: 987, playableDurationSeconds: 123,
            durationSeconds: 123, playbackSeconds: 0, downloadState: .completed,
            preparationState: .prepared(summary: "Ready")
        )
    }

    func testSharedControlsRenderTheirChoiceAndDirectionChangesTheControl() throws {
        let ascending = SortControlHarness(sort: .age, direction: .ascending)
        let descending = SortControlHarness(sort: .age, direction: .descending)
        let ascendingText = try WiltedMacHeadless.recognizedText(ascending, size: CGSize(width: 440, height: 90))
        XCTAssertTrue(ascendingText.joined(separator: "\n").contains("Sort by: Age"), "\(ascendingText)")

        let up = try WiltedMacHeadless.render(ascending, size: CGSize(width: 440, height: 90))
        let down = try WiltedMacHeadless.render(descending, size: CGSize(width: 440, height: 90))
        XCTAssertNotEqual(
            try XCTUnwrap(up.representation(using: .png, properties: [:])),
            try XCTUnwrap(down.representation(using: .png, properties: [:])),
            "the shared direction control paints the selected direction"
        )
        XCTAssertEqual(
            WiltedMacEpisodeListOrder.restoredDirection(from: "Age", direction: "descending"), .descending
        )
    }

    func testDirectionToggleHonorsAndCanonicalizesLegacyOldestSort() {
        let firstToggle = WiltedMacEpisodeListSortControls.toggled(sort: .oldest, direction: .ascending)
        XCTAssertEqual(firstToggle.sort, .age)
        XCTAssertEqual(firstToggle.direction, .ascending, "legacy Oldest is effectively descending before the click")

        let secondToggle = WiltedMacEpisodeListSortControls.toggled(
            sort: firstToggle.sort, direction: firstToggle.direction
        )
        XCTAssertEqual(secondToggle.sort, .age)
        XCTAssertEqual(secondToggle.direction, .descending, "after canonicalization, later clicks reverse normally")
    }

    func testSharedEpisodeMetadataAndArtworkUsePublishedFactsAndFallbackTile() throws {
        let value = episode()
        let metadata = WiltedMacEpisodeMetadata(
            episode: value, lifecycleLabel: value.lifecyclePresentation.primaryLabel,
            identifier: "wilted-parity-metadata", isLarder: true
        )
        let shown = try WiltedMacHeadless.recognizedText(metadata, size: CGSize(width: 620, height: 150))
            .joined(separator: "\n")
        XCTAssertTrue(shown.contains("Parity show"), shown)
        XCTAssertTrue(shown.contains(value.presentation.publicationLabel), shown)
        XCTAssertTrue(shown.contains("16m 27s"), shown)
        XCTAssertTrue(shown.contains("Prepared"), shown)
        XCTAssertFalse(shown.contains("2030"), "intake time is not shown as publication: \(shown)")

        let artwork = try WiltedMacHeadless.render(
            WiltedMacEpisodeArtwork(episode: value, size: 60), size: CGSize(width: 90, height: 90)
        )
        XCTAssertGreaterThan(WiltedMacHeadless.distinctColorCount(in: artwork), 4, "the fallback artwork tile is visible")
    }

    func testInstalledLarderAndPlaylistRowsShowTheSameSourceDuration() throws {
        let value = episode()
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        model.installEpisodeForTesting(value)
        model.seedPodcastQueueMembershipForTesting(value)

        let larderText = try WiltedMacHeadless.recognizedText(
            WiltedMacLarderView(model: model, paneMode: .side),
            size: CGSize(width: 1_100, height: 800)
        ).joined(separator: "\n")
        XCTAssertTrue(larderText.contains("16m 27s"), "the installed Larder row must show the 987-second source: \(larderText)")

        let playlist = Playlist(id: "parity-row-playlist", name: "Parity", kind: .manual, matchAll: true, sortIndex: 0)
        model.playlists.playlists = [playlist]
        model.playlists.entryIDs[playlist.id] = [value.id]
        let playlistText = try WiltedMacHeadless.recognizedText(
            WiltedMacPlaylistView(model: model, playlistID: playlist.id),
            size: CGSize(width: 1_100, height: 700)
        ).joined(separator: "\n")
        XCTAssertTrue(playlistText.contains("16m 27s"), "playlist must show the same source duration: \(playlistText)")
    }

    func testMacEpisodeOrderKeysUseSourceDurationAndPublishedDate() {
        let value = episode()
        let key = WiltedMacEpisodeListOrder.key(for: value)
        XCTAssertEqual(key.id, value.id)
        XCTAssertEqual(key.durationSeconds, 987, "a ready cut does not replace source length")
        XCTAssertEqual(key.publishedAt, value.publishedAt, "intake time is not publication evidence")
    }

    func testLegacyOldestAndArticleAgeKeepTheirEstablishedDateSemantics() {
        let older = episode()
        let newer = WiltedMacEpisode(
            id: "newer", title: "Newer episode", feedTitle: "Parity show", summary: "",
            artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 1_900_000_000),
            publishedAt: Date(timeIntervalSince1970: 1_800_000_000), sourceDurationSeconds: 987,
            durationSeconds: 123, playbackSeconds: 0, downloadState: .completed,
            preparationState: .prepared(summary: "Ready")
        )
        let savedAt = Date(timeIntervalSince1970: 1_750_000_000)
        let article = WiltedMacArticle(
            id: "saved-article", title: "Saved article", source: "example.test",
            url: URL(string: "https://example.test/saved")!, isReady: true,
            durationSeconds: 300, createdAt: savedAt
        )
        let articleKey = WiltedMacEpisodeListOrder.key(for: .article(article))

        XCTAssertEqual(articleKey.durationSeconds, 300)
        XCTAssertEqual(articleKey.publishedAt, savedAt, "an article's saved date remains its Age key")
        let mixed: [WiltedMacLibraryItem] = [.episode(older), .article(article), .episode(newer)]
        XCTAssertEqual(
            WiltedMacEpisodePresentationSections.presentationOrder(mixed, sort: .age).map(\.id),
            [newer.id, article.id, older.id],
            "Larder Age sorts an article by its saved date among episode publication dates"
        )
        let values = [newer, older]
        XCTAssertEqual(
            WiltedMacEpisodeListOrder.ordered(
                values, key: { WiltedMacEpisodeListOrder.key(for: $0) },
                sort: .oldest, direction: .ascending
            ).map(\.id),
            [older.id, newer.id],
            "the legacy Oldest option overrides a caller's ascending direction"
        )
    }

    func testLegacyFeedsChoicesMigrateToMatchingSharedSortAndDirection() {
        let oldest = WiltedMacEpisodeListOrder.legacyFeedsOrdering(.oldest)
        XCTAssertEqual(oldest.sort, .age)
        XCTAssertEqual(oldest.direction, .descending)
        let shortest = WiltedMacEpisodeListOrder.legacyFeedsOrdering(.shortest)
        XCTAssertEqual(shortest.sort, .length)
        XCTAssertEqual(shortest.direction, .ascending)
        let show = WiltedMacEpisodeListOrder.legacyFeedsOrdering(.show)
        XCTAssertEqual(show.sort, .alphabetical)
    }

    func testFeedsAndPlaylistSortsRestoreFromTheirIndependentModelPreferenceKeys() throws {
        let preferences = WiltedMacTestPreferences.ephemeral()
        preferences.set("Alphabetical", forKey: "wilted.mac.episode-list.feeds.sort")
        preferences.set("descending", forKey: "wilted.mac.episode-list.feeds.direction")
        preferences.set("Length", forKey: "wilted.mac.episode-list.playlists.sort")
        preferences.set("descending", forKey: "wilted.mac.episode-list.playlists.direction")
        let model = WiltedMacModel(arguments: [], preferences: preferences)
        let playlist = Playlist(id: "prefs-playlist", name: "Prefs", kind: .manual, matchAll: true, sortIndex: 0)
        model.playlists.playlists = [playlist]

        let feedsText = try WiltedMacHeadless.recognizedText(
            WiltedMacFeedsView(model: model), size: CGSize(width: 1100, height: 700)
        ).joined(separator: "\n")
        let playlistText = try WiltedMacHeadless.recognizedText(
            WiltedMacPlaylistView(model: model, playlistID: playlist.id),
            size: CGSize(width: 1100, height: 700)
        ).joined(separator: "\n")

        XCTAssertTrue(feedsText.contains("Sort by: Alphabetical"), feedsText)
        XCTAssertTrue(playlistText.contains("Sort by: Length"), playlistText)
        XCTAssertEqual(
            WiltedMacEpisodeListOrder.restoredDirection(from: "Alphabetical", direction: "descending"), .descending
        )
        XCTAssertEqual(
            WiltedMacEpisodeListOrder.restoredDirection(from: "Length", direction: "ascending"), .ascending
        )
    }
}
