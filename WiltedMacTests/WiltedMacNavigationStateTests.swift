import Foundation
import WiltedProducer
import XCTest
@testable import WiltedMac

/// Navigation state is one model-owned value: switching destinations keeps it, a fresh model on the
/// same preferences restores it, stale or unknown pieces fall back to defaults, and Clear forgets it.
@MainActor
final class WiltedMacNavigationStateTests: XCTestCase {
    private func model(_ preferences: UserDefaults) -> WiltedMacModel {
        WiltedMacModel(arguments: [], preferences: preferences)
    }

    private func episode(_ id: String) -> WiltedMacEpisode {
        WiltedMacEpisode(
            id: id, title: "Episode \(id)", feedTitle: "Show", summary: "", artworkURL: nil,
            releasedAt: Date(timeIntervalSince1970: 1_700_000_000), durationSeconds: 600, playbackSeconds: 0,
            downloadState: .completed, preparationState: .prepared(summary: "Ready"))
    }

    func testFeedsLarderSettingsFeedsKeepsSelectionDisclosureAndScrollAnchor() {
        let model = model(WiltedMacTestPreferences.ephemeral())
        model.selectedNavigation = .feeds
        model.navigationState.selectedFeedEpisodeIDs = ["a", "b"]
        model.navigationState.isOffListExpanded = true
        model.scrollAnchor(for: .feeds).wrappedValue = "feeds-subscriptions"
        model.scrollAnchor(for: .menu).wrappedValue = "menu-section-ready"
        let saved = model.navigationState

        for destination in [WiltedMacNavigation.menu, .settings, .feeds] {
            model.selectedNavigation = destination
            XCTAssertEqual(model.navigationState, saved, "\(destination)")
        }
        XCTAssertEqual(model.navigationState.selectedFeedEpisodeIDs, ["a", "b"])
        XCTAssertTrue(model.navigationState.isOffListExpanded)
        XCTAssertEqual(model.scrollAnchor(for: .feeds).wrappedValue, "feeds-subscriptions")
        XCTAssertEqual(model.scrollAnchor(for: .menu).wrappedValue, "menu-section-ready")
        XCTAssertNil(model.scrollAnchor(for: .settings).wrappedValue, "each destination keeps its own anchor")
    }

    func testAFreshModelOnTheSamePreferencesReturnsFiltersSearchDraftsAndTheRest() {
        let preferences = WiltedMacTestPreferences.ephemeral()
        let first = model(preferences)
        first.menuFilter = .downloaded
        first.librarySearchQuery = "quiet"
        first.urlDraft = "https://example.test/article"
        first.podcastFeedDraft = "https://example.test/feed.xml"
        first.navigationState.isOffListExpanded = true
        first.navigationState.selectedFeedEpisodeIDs = ["a"]
        first.scrollAnchor(for: .settings).wrappedValue = "settings-sync"

        let second = model(preferences)
        XCTAssertEqual(second.menuFilter, .downloaded)
        XCTAssertEqual(second.librarySearchQuery, "quiet")
        XCTAssertEqual(second.urlDraft, "https://example.test/article")
        XCTAssertEqual(second.podcastFeedDraft, "https://example.test/feed.xml")
        XCTAssertTrue(second.navigationState.isOffListExpanded)
        XCTAssertEqual(second.navigationState.selectedFeedEpisodeIDs, ["a"])
        XCTAssertEqual(second.scrollAnchor(for: .settings).wrappedValue, "settings-sync")
    }

    /// The restored query bypasses the `librarySearchQuery` setter, and the store is not open yet when the
    /// model restores it, so the transcript read has to be scheduled once the store is ready.
    func testARestoredSearchQuerySchedulesItsTranscriptSearchOnceTheStoreIsReady() async throws {
        for (query, scheduled) in [("cormorant", true), ("co", false)] {
            let preferences = WiltedMacTestPreferences.ephemeral()
            var stored = WiltedMacNavigationState()
            stored.librarySearchQuery = query
            preferences.set(try JSONEncoder().encode(stored), forKey: WiltedMacModel.navigationStatePreferenceKey)
            let model = WiltedMacModel(
                arguments: [], stateDirectoryOverride: wiltedTemporaryDirectory("restored-search"),
                storeBootstrap: { url in try LocalLibraryStore(url: url) }, preferences: preferences)
            XCTAssertEqual(model.librarySearchQuery, query)
            model.startStoreBootstrap()
            await model.waitForStoreBootstrap()

            XCTAssertEqual(model.transcriptSearchTask != nil, scheduled, "restored query \(query)")
            await model.transcriptSearchTask?.value
            await model.close()
        }
    }

    func testStaleAndUnknownPiecesFallBackToDefaults() throws {
        let preferences = WiltedMacTestPreferences.ephemeral()
        var stored = WiltedMacNavigationState()
        stored.selectedFeedEpisodeIDs = ["here", "gone"]
        stored.menuFilter = "No Such Group"
        stored.scrollAnchors = ["menu": "menu-section-ready", "retired-destination": "x"]
        stored.librarySearchQuery = "kept"
        preferences.set(try JSONEncoder().encode(stored), forKey: WiltedMacModel.navigationStatePreferenceKey)

        let model = model(preferences)
        XCTAssertNil(model.menuFilter, "an unknown filter is All waiting")
        XCTAssertEqual(model.librarySearchQuery, "kept")
        model.installEpisodeForTesting(episode("here"))
        model.pruneNavigationState()
        XCTAssertEqual(model.navigationState.selectedFeedEpisodeIDs, ["here"], "an episode that left is dropped")
        XCTAssertEqual(model.navigationState.scrollAnchors, ["menu": "menu-section-ready"])
    }

    func testCorruptOrForeignStoredValuesRestoreTheDefaults() throws {
        let corrupt = WiltedMacTestPreferences.ephemeral()
        corrupt.set(Data("not json".utf8), forKey: WiltedMacModel.navigationStatePreferenceKey)
        XCTAssertEqual(model(corrupt).navigationState, .empty)

        let foreign = WiltedMacTestPreferences.ephemeral()
        foreign.set(Data(#"{"librarySearchQuery":"from another build","someFutureField":[1,2]}"#.utf8),
                    forKey: WiltedMacModel.navigationStatePreferenceKey)
        let restored = model(foreign)
        XCTAssertEqual(restored.librarySearchQuery, "from another build")
        XCTAssertFalse(restored.navigationState.isOffListExpanded)
    }

    func testClearForgetsTheSavedViewNowAndAtTheNextLaunch() {
        let preferences = WiltedMacTestPreferences.ephemeral()
        let model = model(preferences)
        XCTAssertFalse(model.hasRetainedNavigationState)
        model.menuFilter = .playable
        model.librarySearchQuery = "x"
        model.urlDraft = "https://example.test"
        XCTAssertTrue(model.hasRetainedNavigationState)

        model.clearNavigationState()
        XCTAssertEqual(model.navigationState, .empty)
        XCTAssertNil(model.menuFilter)
        XCTAssertEqual(model.librarySearchQuery, "")
        XCTAssertFalse(model.hasRetainedNavigationState)
        XCTAssertNil(preferences.data(forKey: WiltedMacModel.navigationStatePreferenceKey))
        XCTAssertEqual(self.model(preferences).navigationState, .empty)
    }

    /// The pages keep their state on the model, not in view-local state that a destination switch drops.
    func testFeedsKeepsSelectionAndDisclosureOnTheModelAndEveryDestinationReportsItsAnchor() throws {
        let feeds = try WiltedMacHeadless.viewSource("WiltedMacFeedsView.swift")
        XCTAssertFalse(feeds.contains("@State private var isOffListExpanded"))
        XCTAssertFalse(feeds.contains("@State private var selectedFeedEpisodeIDs"))
        XCTAssertTrue(feeds.contains("model.navigationState.isOffListExpanded"))
        XCTAssertTrue(feeds.contains("model.navigationState.selectedFeedEpisodeIDs"))
        for (file, destination) in [
            ("WiltedMacFeedsView.swift", ".feeds"), ("WiltedMacMenuView.swift", ".menu"),
            ("WiltedMacSettingsView.swift", ".settings"),
        ] {
            let source = try WiltedMacHeadless.viewSource(file)
            XCTAssertTrue(source.contains("scrollAnchor: model.scrollAnchor(for: \(destination))"), file)
        }
        let root = try WiltedMacHeadless.viewSource("WiltedMacRootView.swift")
        XCTAssertTrue(root.contains(".scrollPosition(id: scrollAnchor ?? .constant(nil), anchor: .top)"))
        XCTAssertTrue(root.contains(".scrollTargetLayout()"))
        let app = try String(
            contentsOf: WiltedMacHeadless.sourceRoot().appendingPathComponent("WiltedMac/WiltedMacApp.swift"),
            encoding: .utf8)
        XCTAssertTrue(app.contains("Button(\"Clear Saved View\")"), "the Clear action")
    }
}
