import AppKit
import SwiftUI
import XCTest
@testable import WiltedMac

/// The bottom-bar composition has to fit inside the window from `windowMinimumWidth` upward. It did not:
/// the scrubber row (a visible slider label, section buttons and a fixed-width volume slider) was wider
/// than the 496pt a minimum window leaves it, which pushed Share and the volume off the right edge.
@MainActor
final class WiltedMacNarrowLayoutTests: XCTestCase {
    private let page = URL(string: "https://example.test/show/episode-1")!

    private func playingModel(link: URL?, navigation: WiltedMacNavigation = .larder) -> WiltedMacModel {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        let episode = WiltedMacEpisode(
            id: "narrow-episode", title: "An episode with a rather long title that keeps going", feedTitle: "A show",
            summary: "", artworkURL: nil, releasedAt: Date(), durationSeconds: 1_800, playbackSeconds: 60,
            downloadState: .completed, preparationState: .prepared(summary: "Ready"),
            feedURL: URL(string: "https://example.test/show.xml"), episodeLink: link)
        model.installPlaybackStateForTesting(episode: episode, isPlaying: false, position: 60, duration: 1_800)
        model.selectedNavigation = navigation
        return model
    }

    /// The width the bar is given at each text size: the window's own minimum for that size and a little
    /// wider, less the rail (sidebar shown) or the whole window (hidden).
    private var barWidths: [(name: String, scale: WiltedTheme.TextScale, width: CGFloat)] {
        WiltedTheme.TextScale.allCases.flatMap { scale -> [(name: String, scale: WiltedTheme.TextScale, width: CGFloat)] in
            let minimum = WiltedMacShellLayout.windowMinimumWidth(scale: scale)
            return [
                ("\(scale) minimum, rail", scale, minimum - WiltedMacShellLayout.railWidth),
                ("\(scale) minimum, sidebar hidden", scale, minimum),
                ("\(scale) minimum+44, rail", scale, minimum + 44 - WiltedMacShellLayout.railWidth),
            ]
        }
    }

    private func bar(_ model: WiltedMacModel, scale: WiltedTheme.TextScale) -> some View {
        WiltedMacCompactPlayer(model: model).environment(\.wiltedTextScale, scale)
    }

    /// Every labelled control is drawn inside the bar at every width the bar can have. Before the fix the
    /// fixed-size scrubber row ran past the right edge, so the readout and the buttons were cut off.
    func testEveryBarControlIsDrawnInsideTheBarFromTheWindowMinimum() throws {
        for link in [page, nil] {
            for navigation in [WiltedMacNavigation.larder, .feeds] {
                let model = playingModel(link: link, navigation: navigation)
                for available in barWidths {
                    let lines = try WiltedMacHeadless.recognizedLines(
                        bar(model, scale: available.scale), size: CGSize(width: available.width, height: 260))
                    var expected = ["of 30:00", "Transcript", "Notes"]
                    if navigation != .larder { expected.append("Larder") }
                    if link == nil { expected.append("No episode page") }
                    for text in expected {
                        XCTAssertTrue(
                            lines.contains { $0.text.contains(text) },
                            "\(text) is drawn at \(available.name) (page: \(link != nil), \(navigation.rawValue))")
                    }
                }
            }
        }
    }

    func testTheBarKeepsItsOneRowFormWhereTheWindowHasRoom() throws {
        let model = playingModel(link: page)
        let wideSize = CGSize(width: 1100, height: 220)
        let narrowSize = CGSize(width: 496, height: 260)
        let wide = try WiltedMacHeadless.recognizedLines(WiltedMacCompactPlayer(model: model), size: wideSize)
        let narrow = try WiltedMacHeadless.recognizedLines(WiltedMacCompactPlayer(model: model), size: narrowSize)
        // Vision reports the vertical position as a fraction of the image; this is points.
        func top(_ lines: [(text: String, top: CGFloat)], _ label: String, in size: CGSize) throws -> CGFloat {
            try XCTUnwrap(lines.first { $0.text.contains(label) }, "\(label) is drawn").top * size.height
        }
        XCTAssertEqual(try top(wide, "Transcript", in: wideSize), try top(wide, "of 30:00", in: wideSize), accuracy: 12,
                       "wide: the scrubber's readout and the section buttons share a row")
        XCTAssertGreaterThan(
            try top(narrow, "Transcript", in: narrowSize), try top(narrow, "of 30:00", in: narrowSize) + 8,
            "narrow: the section buttons wrap beneath the scrubber")
    }

    /// Share is present and drawn inside the bar at every width the bar can have; the fallback names itself.
    func testShareStaysInsideTheBarAtTheWindowMinimum() throws {
        let linkless = playingModel(link: nil)
        for available in barWidths {
            let lines = try WiltedMacHeadless.recognizedLines(
                bar(linkless, scale: available.scale), size: CGSize(width: available.width, height: 260))
            XCTAssertTrue(lines.contains { $0.text.contains("No episode page") },
                          "the share fallback reads in full at \(available.name)")
            XCTAssertFalse(lines.contains { $0.text.contains("Playback position") },
                           "the scrubber's label is for assistive technology only")
        }
        let linked = playingModel(link: page)
        let source = try WiltedMacHeadless.viewSource("WiltedMacPlayerContent.swift")
        let header = try XCTUnwrap(source.range(of: "WiltedMacPlaybackShareLink(model: model)"))
        let rows = try XCTUnwrap(source.range(of: "ViewThatFits(in: .horizontal)"))
        XCTAssertLessThan(header.lowerBound, rows.lowerBound,
                          "Share sits in the always-visible header row, not in a row that can wrap away")
        XCTAssertNotNil(linked.currentPlaybackShareURL)
    }
}
