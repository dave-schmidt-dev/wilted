import SwiftUI
import XCTest
@testable import WiltedMac

/// The Larder row notes, the players' notes and date facts, the sort control and the episode-count
/// control, read from the text hosted views draw. These replace the Mac XCUITest assertions that opened a
/// popover, clicked the sort menu and drove the Episodes-listed picker.
@MainActor
final class WiltedMacEpisodeStatesHostedTests: XCTestCase {
    private let noNotes = "did not include show notes"

    private func episode(notes: String?, published: Date?) -> WiltedMacEpisode {
        var value = WiltedMacEpisode(
            id: "hosted-episode", title: "Hosted episode", feedTitle: "Show", summary: "",
            artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 1_900_000_000), durationSeconds: 600,
            playbackSeconds: 0, downloadState: .completed, preparationState: .prepared(summary: "Ready"))
        value.notes = notes
        value.publishedAt = published
        return value
    }

    private func model(playing episode: WiltedMacEpisode) -> WiltedMacModel {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        model.installPlaybackStateForTesting(
            episode: episode, isPlaying: false, position: 0, duration: 600, queue: [episode.id])
        return model
    }

    private func text<V: View>(_ view: V, size: CGSize = WiltedMacHeadless.windowCanvas) throws -> String {
        try WiltedMacHeadless.recognizedText(view, size: size).joined(separator: "\n")
    }

    func testRowNotesPopoverShowsTheEpisodesNotesOrTheExplicitEmptyState() throws {
        let popover = CGSize(width: 420, height: 360)
        let withNotes = try text(
            WiltedMacEpisodeNotes(episode: episode(notes: "Exact notes for this one", published: Date()),
                                  prefix: "wilted-larder") { EmptyView() }, size: popover)
        XCTAssertTrue(withNotes.contains("Hosted episode"), withNotes)
        XCTAssertTrue(withNotes.contains("Exact notes"), withNotes)
        XCTAssertFalse(withNotes.contains(noNotes))

        for empty in [nil, ""] {
            let shown = try text(
                WiltedMacEpisodeNotes(episode: episode(notes: empty, published: Date()), prefix: "wilted-larder") {
                    EmptyView()
                }, size: popover)
            XCTAssertTrue(shown.contains(noNotes), "notes \(empty ?? "nil"): \(shown)")
        }
    }

    func testRowTitleIsTheButtonThatOpensNotes() throws {
        let value = episode(notes: "Notes", published: Date())
        let shown = try text(WiltedMacLarderEpisodeNotesTitle(episode: value), size: CGSize(width: 400, height: 60))
        XCTAssertTrue(shown.contains("Hosted episode"), shown)
        let source = try WiltedMacHeadless.viewSource("WiltedMacEpisodeNotes.swift")
        XCTAssertTrue(source.contains(".accessibilityLabel(\"Show notes for \\(episode.title)\")"))
        XCTAssertTrue(source.contains(".accessibilityIdentifier(\"\\(prefix)-show-notes-\\(episode.id)\")"))
        let rows = try WiltedMacHeadless.viewSource("WiltedMacLarderView+Rows.swift")
        XCTAssertTrue(rows.contains("WiltedMacLarderEpisodeNotesTitle(episode: episode)"))
    }

    func testPlaybackNotesUseTheSameExplicitEmptyStateAsTheRow() throws {
        let size = CGSize(width: 600, height: 300)
        for empty in [nil, ""] {
            let shown = try text(
                WiltedMacNotesPanel(model: model(playing: episode(notes: empty, published: Date()))), size: size)
            XCTAssertTrue(shown.contains(noNotes), "notes \(empty ?? "nil"): \(shown)")
        }
        let shown = try text(
            WiltedMacNotesPanel(model: model(playing: episode(notes: "Real notes here", published: Date()))), size: size)
        XCTAssertTrue(shown.contains("Real notes"), shown)
        XCTAssertFalse(shown.contains(noNotes))
    }

    func testEveryPlayerStatesAMissingPublicationDateInsteadOfTheIntakeDate() throws {
        let intake = Date(timeIntervalSince1970: 1_900_000_000).formatted(date: .abbreviated, time: .omitted)
        let undated = model(playing: episode(notes: nil, published: nil))
        XCTAssertEqual(undated.currentEpisode?.presentation.playerSubtitleLabel, "Show · Date unknown")

        let surfaces: [(String, AnyView, CGSize)] = [
            ("side", AnyView(WiltedMacNowPlayingPane(model: undated, state: .constant(WiltedMacPaneState()))),
             CGSize(width: 420, height: 700)),
            ("bottom", AnyView(WiltedMacCompactPlayer(model: undated)), CGSize(width: 1100, height: 240)),
            ("full", AnyView(WiltedMacFullWindowPlayer(
                model: undated, presentation: .constant(nil), onSelect: { _ in }, onCollapse: { _ in })),
             WiltedMacHeadless.windowCanvas),
        ]
        for (name, view, size) in surfaces {
            let shown = try text(view, size: size)
            XCTAssertTrue(shown.contains("Date unknown"), "\(name) player states the missing date: \(shown)")
            XCTAssertFalse(shown.contains(intake), "\(name) player must not show the intake date")
        }

        let publication = Date(timeIntervalSince1970: 1_700_000_000)
        let dated = model(playing: episode(notes: nil, published: publication))
        XCTAssertEqual(
            dated.currentEpisode?.presentation.playerSubtitleLabel,
            "Show · " + publication.formatted(date: .abbreviated, time: .omitted))
    }

    func testSortControlNamesItselfAndShowsADirectionOnlyForACalculatedSort() throws {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        let larder = { try self.text(WiltedMacLarderView(model: model, paneMode: .side)) }
        var shown = try larder()
        XCTAssertTrue(shown.contains("Sort by: Custom"), shown)
        model.larderSort = .age
        shown = try larder()
        XCTAssertTrue(shown.contains("Sort by: Age"), shown)
        XCTAssertEqual(model.larderSortDirection, .ascending)
        model.larderSortDirection = .descending
        XCTAssertEqual(model.larderSortDirection.displayName, "Descending")
        XCTAssertEqual(WiltedMacLarderSort.presentationOptions.map(\.displayName), ["Length", "Age", "Alphabetical", "Custom"])

        // The direction button is an icon, so its presence and names are pinned where they are declared.
        let source = try WiltedMacHeadless.viewSource("WiltedMacLarderView.swift")
        XCTAssertTrue(source.contains("if model.larderSort != .custom {"))
        XCTAssertTrue(source.contains(".accessibilityLabel(\"Larder sort direction: \\(model.larderSortDirection.displayName)\")"))
        XCTAssertTrue(source.contains(".accessibilityIdentifier(\"wilted-larder-sort-direction\")"))
    }

    func testEpisodeCountControlOffersFiveTenAndCustomWithNumericInputOnlyForCustom() throws {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        let shown = try text(WiltedMacSettingsView(model: model), size: CGSize(width: 900, height: 1300))
        XCTAssertTrue(shown.contains("Episodes to list when adding a feed"), shown)
        XCTAssertFalse(shown.contains("Custom episodes"), "numeric input appears only for Custom")
        XCTAssertNil(WiltedAutomationSettings.validInitialEpisodeMetadataCount(0))
        XCTAssertNil(WiltedAutomationSettings.validInitialEpisodeMetadataCount(101))
        XCTAssertEqual(WiltedAutomationSettings.validInitialEpisodeMetadataCount(7), 7)
    }
}
