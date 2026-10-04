import SwiftUI
import XCTest
@testable import WiltedMac

/// Feeds as the reader sees it: the view is hosted headlessly and its rendered text is read back, so
/// these count what is drawn, not what the source declares. SwiftUI vends no accessibility tree to a
/// hosted view with no assistive technology attached, so rendered text is the machine-readable form.
@MainActor
final class WiltedMacFeedsStructureTests: XCTestCase {
    private let arguments = ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts"]
    private let tall = CGSize(width: 1_000, height: 2_000)

    private func lines(_ model: WiltedMacModel) throws -> [(text: String, top: CGFloat)] {
        try WiltedMacHeadless.recognizedLines(WiltedMacFeedsView(model: model), size: tall)
    }

    private func index(of prefix: String, in lines: [(text: String, top: CGFloat)]) -> Int? {
        lines.firstIndex { $0.text.hasPrefix(prefix) || $0.text.hasPrefix("> \(prefix)") }
    }

    func testFeedsDrawsOneHeadingAndOneMessageWithOneUndoPerOperation() async throws {
        let model = await WiltedMacHeadless.model(self, arguments)
        let episode = try XCTUnwrap(model.feedsEpisodes.first)
        model.podcastOperationMessage = "Skipped Quiet Machines."
        model.undoableSkip = episode

        let shown = try lines(model).map(\.text)
        XCTAssertEqual(shown.filter { $0 == "Feeds" }.count, 1, "one Feeds heading: \(shown)")
        XCTAssertEqual(shown.filter { $0.contains("Skipped Quiet Machines") }.count, 1, "one operation message: \(shown)")
        XCTAssertEqual(shown.filter { $0.contains("Undo completion") }.count, 1, "one Undo: \(shown)")
        XCTAssertFalse(shown.contains { $0.hasPrefix("Last updated") }, "the label is Last refreshed")
    }

    func testRenderedSectionOrderIsOperationsThenSubscriptionsThenOffTheList() async throws {
        let model = await WiltedMacHeadless.model(self, arguments)
        let episode = try XCTUnwrap(model.feedsEpisodes.first)
        model.decideFeedEpisodes(.skip, episodes: [episode])
        await WiltedMacHeadless.drainDecisions(model)
        await WiltedMacHeadless.eventually("the skipped episode is off the list") { !model.skippedFeedEpisodes.isEmpty }

        let shown = try lines(model)
        let heading = try XCTUnwrap(index(of: "Feeds", in: shown), "\(shown.map(\.text))")
        let refreshed = try XCTUnwrap(index(of: "Last refreshed", in: shown), "\(shown.map(\.text))")
        let subscriptions = try XCTUnwrap(index(of: "Subscriptions", in: shown), "\(shown.map(\.text))")
        let offList = try XCTUnwrap(index(of: "Off the list", in: shown), "\(shown.map(\.text))")
        XCTAssertLessThan(heading, refreshed, "the heading, then the operation status")
        XCTAssertLessThan(refreshed, subscriptions, "active operations before subscriptions")
        XCTAssertLessThan(subscriptions, offList, "Off the list last")
        XCTAssertEqual(shown.map(\.text).filter { $0.contains("Off the list") }.count, 1)
    }

    func testPerFeedCountsExcludeRetiredAndHiddenEpisodes() async throws {
        let model = await WiltedMacHeadless.model(self, arguments)
        let base = try XCTUnwrap(model.episodes.first)
        let feedID = try XCTUnwrap(model.subscriptions.first?.id)
        func extra(_ id: String, retired: Bool = false) -> WiltedMacEpisode {
            var value = WiltedMacEpisode(
                id: id, title: id, feedTitle: base.feedTitle, summary: "", artworkURL: nil,
                releasedAt: base.releasedAt, durationSeconds: 60, playbackSeconds: 0, downloadState: .completed,
                preparationState: .prepared(summary: "Ready"))
            value.feedID = feedID
            if retired { value.retiredAt = Date() }
            return value
        }
        let retired = extra("extra-retired", retired: true)
        let hidden = extra("extra-hidden")
        let shown = extra("extra-shown")
        let before = model.larderEpisodeCount(forFeedID: feedID)
        for value in [retired, hidden, shown] { model.installEpisodeForTesting(value) }
        model.hiddenEpisodeIDs.insert(hidden.id)

        XCTAssertEqual(model.larderEpisodeCount(forFeedID: feedID), before + 1,
                       "only the visible, unretired episode is counted")
        let text = try lines(model).map(\.text)
        let noun = before + 1 == 1 ? "episode" : "episodes"
        XCTAssertTrue(text.contains { $0.contains("\(before + 1) \(noun) from this feed") }, "\(text)")
    }

    func testKeepIsFilledAndSkipIsOutlined() throws {
        let components = try WiltedMacHeadless.viewSource("WiltedMacFeedsComponents.swift")
        XCTAssertTrue(components.contains(".buttonStyle(.borderedProminent)"), "Keep is the filled answer")
        XCTAssertTrue(components.contains(".buttonStyle(WiltedMacOutlinedButtonStyle())"), "Skip is outlined")
        XCTAssertTrue(components.contains("strokeBorder(leaf, lineWidth: 1)"))
        XCTAssertEqual(WiltedMacHeadless.occurrences(of: ".buttonStyle(.bordered)", in: components), 0)
    }

    func testDownloadedFilterWithNothingDownloadedExplainsItself() async throws {
        let model = await WiltedMacHeadless.model(self, ["--wilted-ui-fixture-ready"])
        model.menuFilter = .downloaded
        XCTAssertTrue(model.menuEpisodes(in: .downloaded).isEmpty)
        let text = try WiltedMacHeadless.recognizedText(
            WiltedMacMenuView(model: model, paneMode: .side), size: CGSize(width: 1_000, height: 1_200))
        XCTAssertTrue(text.contains { $0.contains("Downloaded audio is empty") }, "\(text)")
    }

    func testAddFeedCountControlIsLabelledEpisodesListedWithFiveTenAndCustom() throws {
        let source = try WiltedMacHeadless.viewSource("WiltedMacFeedsView.swift")
        XCTAssertTrue(source.contains("Picker(\"Episodes listed\", selection: initialMetadataPreset)"))
        for option in ["Text(\"5\").tag(5)", "Text(\"10\").tag(10)", "Text(\"Custom\").tag(0)"] {
            XCTAssertTrue(source.contains(option), option)
        }
        XCTAssertEqual(WiltedMacHeadless.occurrences(of: "WiltedMacPodcastOperationMessage(model: model)", in: source), 1,
                       "the message component is mounted once")
    }
}
