import AppKit
import SwiftUI
import Vision
import XCTest
@testable import WiltedMac

/// The bottom-bar composition has to fit inside the window from `windowMinimumWidth` upward. It did not:
/// the scrubber row (a visible slider label, section buttons and a fixed-width volume slider) was wider
/// than the 496pt a minimum window leaves it, which pushed Share and the volume off the right edge.
@MainActor
final class WiltedMacNarrowLayoutTests: XCTestCase {
    func testWholeMinimumWindowKeepsAuthorDateWhileLongTitleCompresses() async throws {
        try await inspectMinimumLarder(assertDate: true)
    }

    func testWholeMinimumWindowKeepsCompleteGroupRemovalAction() async throws {
        try await inspectMinimumLarder(assertDate: false)
    }

    private func inspectMinimumLarder(assertDate: Bool) async throws {
        let model = await WiltedMacHeadless.model(self, ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts", "--wilted-ui-fixture-prepared"])
        model.setTextScale(.standard)
        let published = Date(timeIntervalSince1970: 1_700_000_000)
        model.episodes = (1...9).map { index in
            WiltedMacEpisode(id: "minimum-\(index)", title: "An exceptionally long title that must yield space to author dates and complete controls \(index)", feedTitle: "Garden Radio", summary: "", artworkURL: nil,
                releasedAt: published, durationSeconds: 3723, playbackSeconds: 0,
                downloadState: .completed, preparationState: .prepared(summary: "Ready"))
        }
        model.podcastQueueIDs = model.episodes.map(\.id); model.selectedNavigation = .larder
        let width = WiltedMacShellLayout.windowMinimumWidth(scale: .standard)
        XCTAssertEqual(width, 576)
        for visible in [true, false] {
            model.isSidebarVisible = visible
            let bitmap = try WiltedMacHeadless.render(WiltedMacRootView(model: model), size: CGSize(width: width, height: 1400))
            XCTAssertEqual(bitmap.pixelsWide, 576, "OCR receives the actual whole-window bitmap, without24pt helper padding")
            let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false; request.minimumTextHeight = 0.004
            try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage)).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            if assertDate {
                XCTAssertEqual(text.components(separatedBy: published.formatted(date: .numeric, time: .omitted)).count - 1, 9, text)
                XCTAssertTrue(text.contains("1h 02m"), text)
            } else { XCTAssertTrue(text.contains("Remove all 9 from Larder"), text) }
            for dark in [false, true] {
                let capture = dark ? try WiltedMacHeadless.render(WiltedMacRootView(model: model).environment(\.colorScheme, .dark), size: CGSize(width: width, height: 1400)) : bitmap
                let attachment = XCTAttachment(data: try XCTUnwrap(capture.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
                attachment.name = "formats-minimum-\(assertDate ? "date" : "actions")-\(visible ? "automatic-rail" : "collapsed-rail")-\(dark ? "dark" : "light")"; attachment.lifetime = .keepAlways; add(attachment)
            }
        }
    }

    func testTwoLineLarderTitlesKeepDatesAndControlsAcrossWholeWindowWidths() async throws {
        let model = await WiltedMacHeadless.model(self,
            ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts", "--wilted-ui-fixture-prepared"])
        let published = Date(timeIntervalSince1970: 1_700_000_000)
        model.episodes = (1...3).map { index in
            WiltedMacEpisode(id: "two-line-\(index)", title: "Evening garden report Harvest tomorrow \(index)",
                feedTitle: "Garden Radio", summary: "", artworkURL: nil, releasedAt: published,
                durationSeconds: 3723, playbackSeconds: 0, downloadState: .completed,
                preparationState: .prepared(summary: "Ready"))
        }
        model.podcastQueueIDs = model.episodes.map(\.id); model.selectedNavigation = .larder
        for scale in [WiltedTheme.TextScale.standard, .large] {
            model.setTextScale(scale)
            let minimum = WiltedMacShellLayout.windowMinimumWidth(scale: scale)
            XCTAssertEqual(minimum, scale == .standard ? 576 : 672)
            for width in [minimum, CGFloat(1400)] {
                for visible in [true, false] {
                    model.isSidebarVisible = visible
                    let layout = WiltedMacShellLayout.resolve(windowWidth: width, scale: scale, sidebarVisible: visible)
                    XCTAssertEqual(layout.sidebar, visible ? (width == minimum ? .rail : .full) : .rail)
                    let size = CGSize(width: width, height: 1400)
                    let bitmap = try WiltedMacHeadless.render(WiltedMacRootView(model: model), size: size)
                    XCTAssertEqual(bitmap.pixelsWide, Int(width), "the actual whole window has no hidden OCR margin")
                    let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = true; request.recognitionLanguages = ["en-US"]
                    request.minimumTextHeight = 0.004
                    try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage)).perform([request])
                    let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                    XCTAssertEqual(text.components(separatedBy: published.formatted(date: .numeric, time: .omitted)).count - 1, 3, text)
                    XCTAssertTrue(text.contains("1h 02m"), text)
                    XCTAssertTrue(text.contains("Remove all 3 from Larder"), text)
                    XCTAssertEqual(text.components(separatedBy: "tomorrow").count - 1, 3, "all three unique title suffixes remain visible: \(text)")
                    for dark in [false, true] {
                        let capture = dark ? try WiltedMacHeadless.render(
                            WiltedMacRootView(model: model).environment(\.colorScheme, .dark), size: size) : bitmap
                        let attachment = XCTAttachment(data: try XCTUnwrap(capture.representation(using: .png, properties: [:])),
                            uniformTypeIdentifier: "public.png")
                        attachment.name = "larder-two-lines-\(scale)-\(Int(width))-\(layout.sidebar)-\(dark ? "dark" : "light")"
                        attachment.lifetime = .keepAlways; add(attachment)
                    }
                }
            }
        }
        let rows = try WiltedMacHeadless.viewSource("WiltedMacLarderView+Rows.swift")
        for identifier in ["wilted-larder-play-", "wilted-larder-remove-", "wilted-larder-metadata-"] {
            XCTAssertTrue(rows.contains(identifier), "existing row actions and metadata retain their identifiers")
        }
        XCTAssertTrue(rows.contains("Self.readyActionSlotWidth"))
        XCTAssertTrue(rows.contains("Self.trailingActionSlotsWidth"))
    }

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

    private struct BarWidthCase {
        let name: String
        let scale: WiltedTheme.TextScale
        let windowWidth: CGFloat
        let sidebar: WiltedMacSidebarMode
        let width: CGFloat
    }

    /// Derive the player viewport from the actual shell columns. The compact player adds its own
    /// horizontal inset; the OCR canvas must not add another margin inside that viewport.
    private var barWidths: [BarWidthCase] {
        WiltedTheme.TextScale.allCases.flatMap { scale -> [BarWidthCase] in
            let minimum = WiltedMacShellLayout.windowMinimumWidth(scale: scale)
            let configurations: [(name: String, windowWidth: CGFloat, sidebarVisible: Bool)] = [
                ("\(scale) minimum, automatic rail", minimum, true),
                ("\(scale) minimum, collapsed rail", minimum, false),
                ("\(scale) minimum+44, automatic rail", minimum + 44, true),
            ]
            return configurations.map { configuration in
                let layout = WiltedMacShellLayout.resolve(
                    windowWidth: configuration.windowWidth, scale: scale,
                    sidebarVisible: configuration.sidebarVisible)
                let sidebarWidth = layout.sidebar == .rail
                    ? WiltedMacShellLayout.railWidth
                    : WiltedTheme.scaled(WiltedMacShellLayout.sidebarIdealWidth, scale: scale)
                return BarWidthCase(
                    name: configuration.name, scale: scale, windowWidth: configuration.windowWidth,
                    sidebar: layout.sidebar,
                    width: configuration.windowWidth - sidebarWidth - WiltedMacLarderLayout.dividerWidth)
            }
        }
    }

    private func recognizedPlayerLines<V: View>(
        _ view: V, size: CGSize
    ) throws -> [(text: String, top: CGFloat)] {
        let pixelScale = 2
        let hostingView = NSHostingView(
            rootView: view.environment(\.colorScheme, .light)
                .frame(width: size.width, height: size.height, alignment: .topLeading))
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width) * pixelScale,
            pixelsHigh: Int(size.height) * pixelScale, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bitmapFormat: [], bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = size
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.004
        try VNImageRequestHandler(cgImage: try XCTUnwrap(bitmap.cgImage)).perform([request])
        return (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first.map { ($0.string, 1 - observation.boundingBox.maxY) }
        }.sorted { $0.1 < $1.1 }
    }

    private func playerViewportWidth(
        windowWidth: CGFloat, scale: WiltedTheme.TextScale, sidebarVisible: Bool
    ) -> CGFloat {
        let layout = WiltedMacShellLayout.resolve(
            windowWidth: windowWidth, scale: scale, sidebarVisible: sidebarVisible)
        let sidebarWidth = layout.sidebar == .rail
            ? WiltedMacShellLayout.railWidth
            : WiltedTheme.scaled(WiltedMacShellLayout.sidebarIdealWidth, scale: scale)
        return windowWidth - sidebarWidth - WiltedMacLarderLayout.dividerWidth
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
                    XCTAssertEqual(available.sidebar, .rail, "\(available.name) retains the rail")
                    XCTAssertEqual(available.width,
                                   available.windowWidth - WiltedMacShellLayout.railWidth
                                       - WiltedMacLarderLayout.dividerWidth,
                                   "\(available.name) reserves the rail and split divider")
                    let lines = try recognizedPlayerLines(
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
        let minimum = WiltedMacShellLayout.windowMinimumWidth(scale: .standard)
        let wideWindow = WiltedMacShellLayout.sidePaneMinimumWidth(scale: .standard) - 1
        let wideLayout = WiltedMacShellLayout.resolve(windowWidth: wideWindow, scale: .standard)
        XCTAssertEqual(wideLayout.pane, .bottom, "the compact player remains in the bottom bar at this width")
        let wideSize = CGSize(width: playerViewportWidth(
            windowWidth: wideWindow, scale: .standard, sidebarVisible: true), height: 220)
        let narrowSize = CGSize(width: playerViewportWidth(
            windowWidth: minimum, scale: .standard, sidebarVisible: true), height: 260)
        let wide = try recognizedPlayerLines(WiltedMacCompactPlayer(model: model), size: wideSize)
        let narrow = try recognizedPlayerLines(WiltedMacCompactPlayer(model: model), size: narrowSize)
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
            XCTAssertEqual(available.sidebar, .rail, "\(available.name) retains the rail")
            let lines = try recognizedPlayerLines(
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
