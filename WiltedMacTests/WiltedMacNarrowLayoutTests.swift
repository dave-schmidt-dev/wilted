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
                releasedAt: published.addingTimeInterval(Double(index) * 86_400), durationSeconds: 3723, playbackSeconds: 0,
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
                for episode in model.episodes {
                    XCTAssertEqual(text.components(separatedBy: episode.releasedAt.formatted(date: .numeric, time: .omitted)).count - 1, 1,
                                   "Each episode owns one date line; the article has a separate date: \(text)")
                }
                XCTAssertTrue(text.contains("1h 02m"), text)
            } else { XCTAssertTrue(text.contains("Remove all 9 from Larder"), text) }
            for dark in [false, true] {
                let capture = dark ? try WiltedMacHeadless.render(WiltedMacRootView(model: model).environment(\.colorScheme, .dark), size: CGSize(width: width, height: 1400)) : bitmap
                let attachment = XCTAttachment(data: try XCTUnwrap(capture.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
                attachment.name = "formats-minimum-\(assertDate ? "date" : "actions")-\(visible ? "automatic-rail" : "collapsed-rail")-\(dark ? "dark" : "light")"; attachment.lifetime = .keepAlways; add(attachment)
            }
        }
    }

    func testOneLineLarderTitlesKeepDatesAndControlsAcrossWholeWindowWidths() async throws {
        let model = await WiltedMacHeadless.model(self,
            ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts", "--wilted-ui-fixture-prepared"])
        let published = Date(timeIntervalSince1970: 1_700_000_000)
        model.episodes = (1...3).map { index in
            WiltedMacEpisode(id: "three-line-\(index)", title: "Evening garden report Harvest tomorrow \(index)",
                feedTitle: "Garden Radio", summary: "", artworkURL: nil, releasedAt: published.addingTimeInterval(Double(index) * 86_400),
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
                    for episode in model.episodes {
                        XCTAssertEqual(text.components(separatedBy: episode.releasedAt.formatted(date: .numeric, time: .omitted)).count - 1, 1,
                                       "Each episode owns one date line; the article has a separate date: \(text)")
                    }
                    XCTAssertTrue(text.contains("1h 02m"), text)
                    XCTAssertTrue(text.contains("Remove all 3 from Larder"), text)
                    XCTAssertEqual(text.components(separatedBy: "Evening").count - 1, 3, "each one-line title remains visible: \(text)")
                    for dark in [false, true] {
                        let capture = dark ? try WiltedMacHeadless.render(
                            WiltedMacRootView(model: model).environment(\.colorScheme, .dark), size: size) : bitmap
                        let attachment = XCTAttachment(data: try XCTUnwrap(capture.representation(using: .png, properties: [:])),
                            uniformTypeIdentifier: "public.png")
                        attachment.name = "larder-three-lines-\(scale)-\(Int(width))-\(layout.sidebar)-\(dark ? "dark" : "light")"
                        attachment.lifetime = .keepAlways; add(attachment)
                    }
                }
            }
        }
        let rows = try WiltedMacHeadless.viewSource("WiltedMacLarderView+Rows.swift")
        for identifier in ["wilted-larder-play-", "wilted-larder-remove-", "wilted-larder-metadata-"] {
            XCTAssertTrue(rows.contains(identifier), "existing row actions and metadata retain their identifiers")
        }
        XCTAssertTrue(rows.contains("WiltedMacLarderView.readyActionSlotWidth"))
        XCTAssertTrue(rows.contains("Self.trailingActionSlotsWidth"))
    }

    func testLongLarderAndActiveWorkRowsHaveExactlyThreeLinesAtMinimumAndFullWidths() throws {
        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: wiltedTemporaryDirectory("three-line-rows"),
                                   preferences: WiltedMacTestPreferences.ephemeral())
        model.setTextScale(.standard)
        let published = Date(timeIntervalSince1970: 1_700_000_000)
        let states: [(WiltedMacEpisodeDownloadState, WiltedMacEpisodePreparationState)] = [
            (.notDownloaded, .notPrepared), (.downloading(received: 25, expected: 100), .notPrepared),
            (.completed, .preparing(stage: "Transcribing")), (.completed, .prepared(summary: "Ready"))
        ]
        let minimum = WiltedMacShellLayout.windowMinimumWidth(scale: .standard) - WiltedMacShellLayout.railWidth
        for (index, state) in states.enumerated() {
            let episode = WiltedMacEpisode(id: "three-line-\(index)",
                title: "An exceptionally long garden report title that must stay on a single line even at the minimum window width",
                feedTitle: "Garden Radio", summary: "", artworkURL: nil, releasedAt: published,
                durationSeconds: 3723, playbackSeconds: 0, downloadState: state.0, preparationState: state.1)
            model.installEpisodeForTesting(episode)
            for width in [minimum, CGFloat(1400)] {
                for active in [false, true] {
                    let view = WiltedMacLarderView(model: model, paneMode: .side)
                        .larderRow(episode, position: 1, count: 1, showsGroupName: active)
                    let lines = try WiltedMacHeadless.recognizedLines(view, size: CGSize(width: width, height: 200))
                    var baselines: [CGFloat] = []
                    for line in lines where !baselines.contains(where: { abs($0 - line.top) < 0.025 }) {
                        baselines.append(line.top)
                    }
                    XCTAssertEqual(baselines.count, 3, "state=\(index) width=\(width) active=\(active): \(lines)")
                    let date = try XCTUnwrap(lines.first { $0.text.contains(published.formatted(date: .numeric, time: .omitted)) })
                    let feed = try XCTUnwrap(lines.first { $0.text.contains("Garden Radio") })
                    XCTAssertGreaterThan(date.top, feed.top + 0.025, "date owns its third line: \(lines)")
                    XCTAssertTrue(lines.contains { $0.text.contains("1h 02m") }, "\(lines)")
                    let bitmap = try WiltedMacHeadless.render(view, size: CGSize(width: width, height: 200))
                    let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
                                                   uniformTypeIdentifier: "public.png")
                    attachment.name = "three-line-row-\(index)-\(Int(width))-\(active ? "active" : "larder")"
                    attachment.lifetime = .keepAlways; add(attachment)
                }
            }
        }
    }

    func testLarderActionFramesAreEqualAcrossDownloadPreparingAndPlayableStates() throws {
        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: wiltedTemporaryDirectory("action-frames"),
                                   preferences: WiltedMacTestPreferences.ephemeral())
        model.setTextScale(.standard)
        let states: [(WiltedMacEpisodeDownloadState, WiltedMacEpisodePreparationState)] = [
            (.notDownloaded, .notPrepared), (.downloading(received: 25, expected: 100), .notPrepared),
            (.completed, .preparing(stage: "Transcribing")), (.completed, .prepared(summary: "Ready"))
        ]
        var sizes: [CGSize] = []
        for (index, state) in states.enumerated() {
            let episode = WiltedMacEpisode(id: "action-frame-\(index)", title: "Action frame", feedTitle: "Show",
                summary: "", artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 1_700_000_000), durationSeconds: 600, playbackSeconds: 0,
                downloadState: state.0, preparationState: state.1)
            let control = WiltedMacLarderView(model: model, paneMode: .side)
                .nextStepControl(episode, group: WiltedMacModel.larderGroup(for: episode))
                .environment(\.wiltedTextScale, .standard).fixedSize()
            let host = NSHostingView(rootView: control)
            host.layoutSubtreeIfNeeded()
            sizes.append(host.fittingSize)
        }
        let expected = try XCTUnwrap(sizes.first)
        XCTAssertGreaterThan(expected.width, 0); XCTAssertGreaterThan(expected.height, 0)
        for size in sizes.dropFirst() {
            XCTAssertEqual(size.width, expected.width, accuracy: 0.5, "\(sizes)")
            XCTAssertEqual(size.height, expected.height, accuracy: 0.5, "\(sizes)")
        }
    }

    func testReadyArticlePlayActionStartsTheLoadedAudio() async throws {
        let model = await WiltedMacHeadless.model(self, ["--wilted-ui-fixture-ready"], suffix: "article-play-action")
        let article = try XCTUnwrap(model.articles.first)
        XCTAssertTrue(article.isReady)
        let before = try XCTUnwrap(model.playbackCheckpointStateForTesting())
        XCTAssertFalse(before.isPlaying)
        WiltedMacLarderArticleAction(model: model, article: article).play()
        await model.waitForPlaybackOperationForTesting()
        let after = try XCTUnwrap(model.playbackCheckpointStateForTesting())
        XCTAssertTrue(after.isPlaying, "The shipping Play action starts the loaded engine, not just the player view")
        XCTAssertEqual(model.selectedArticleID, article.id)
        await model.close()
    }

    func testLongArticleRowsHaveThreeLinesAndShareEpisodeActionFrames() throws {
        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: wiltedTemporaryDirectory("article-three-lines"),
                                   preferences: WiltedMacTestPreferences.ephemeral())
        model.setTextScale(.standard)
        let published = Date(timeIntervalSince1970: 1_700_000_000)
        let episode = WiltedMacEpisode(id: "article-slot-reference", title: "Episode", feedTitle: "Show", summary: "",
            artworkURL: nil, releasedAt: published, durationSeconds: 3723, playbackSeconds: 0,
            downloadState: .completed, preparationState: .prepared(summary: "Ready"))
        let referenceHost = NSHostingView(rootView: WiltedMacLarderView(model: model, paneMode: .side)
            .nextStepControl(episode, group: .playable).fixedSize())
        referenceHost.layoutSubtreeIfNeeded()
        let reference = referenceHost.fittingSize
        for ready in [false, true] {
            let article = WiltedMacArticle(id: "long-article", title: "An exceptionally long garden article title that must remain on one line at minimum width",
                source: "Garden Radio", url: URL(string: "https://example.test/article")!, isReady: ready,
                durationSeconds: 3723, createdAt: published)
            for width in [WiltedMacShellLayout.windowMinimumWidth(scale: .standard) - WiltedMacShellLayout.railWidth, CGFloat(1400)] {
                let row = WiltedMacArticleRow(model: model, article: article).environment(\.wiltedTextScale, .standard)
                let lines = try WiltedMacHeadless.recognizedLines(row, size: CGSize(width: width, height: 200))
                var baselines: [CGFloat] = []
                for line in lines where !baselines.contains(where: { abs($0 - line.top) < 0.025 }) { baselines.append(line.top) }
                XCTAssertEqual(baselines.count, 3, "ready=\(ready) width=\(width): \(lines)")
                let date = try XCTUnwrap(lines.first { $0.text.contains(published.formatted(date: .numeric, time: .omitted)) })
                let feed = try XCTUnwrap(lines.first { $0.text.contains("Garden Radio") })
                XCTAssertGreaterThan(date.top, feed.top + 0.025)
                XCTAssertTrue(lines.contains { $0.text.contains("1h 02m") }, "\(lines)")
                let bitmap = try WiltedMacHeadless.render(row, size: CGSize(width: width, height: 200))
                let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
                attachment.name = "article-three-lines-\(ready)-\(Int(width))"
                attachment.lifetime = .keepAlways; add(attachment)
                if ready {
                    let mixed = VStack(spacing: 0) {
                        WiltedMacLarderView(model: model, paneMode: .side)
                            .larderRow(episode, position: 1, count: 1, showsGroupName: false)
                        row
                    }
                    .environment(\.wiltedTextScale, .standard)
                    let mixedBitmap = try WiltedMacHeadless.render(mixed, size: CGSize(width: width, height: 200))
                    let centers = renderedPlayIconCenters(in: mixedBitmap)
                    XCTAssertEqual(centers.count, 2, "The actual mixed rows must render both Play triangles: \(centers)")
                    if centers.count == 2 {
                        XCTAssertEqual(centers[0].x, centers[1].x, accuracy: 1, "Episode and article primary actions share a column")
                    }
                    let mixedAttachment = XCTAttachment(data: try XCTUnwrap(mixedBitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
                    mixedAttachment.name = "mixed-row-action-column-\(Int(width))"
                    mixedAttachment.lifetime = .keepAlways; add(mixedAttachment)
                }
            }
            let host = NSHostingView(rootView: WiltedMacLarderArticleAction(model: model, article: article).fixedSize())
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.fittingSize.width, reference.width, accuracy: 0.5)
            XCTAssertEqual(host.fittingSize.height, reference.height, accuracy: 0.5)
        }
    }

    /// Reads the two solid right-pointing Play glyphs from native pixels, rather than measuring
    /// an outer frame that can stay equal while the action moves within a mixed row.
    private func renderedPlayIconCenters(in bitmap: NSBitmapImageRep) -> [CGPoint] {
        let width = bitmap.pixelsWide, height = bitmap.pixelsHigh
        var ink = Set<Int>()
        for y in 0..<height {
            for x in (width * 3 / 4)..<width {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   max(color.redComponent, color.greenComponent, color.blueComponent) < 0.4 {
                    ink.insert(y * width + x)
                }
            }
        }
        var centers: [CGPoint] = []
        while let seed = ink.first {
            ink.remove(seed)
            var pending = [seed], component = [seed]
            while let point = pending.popLast() {
                let x = point % width, y = point / width
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
                    where nx >= 0 && nx < width && ny >= 0 && ny < height {
                    let neighbor = ny * width + nx
                    if ink.remove(neighbor) != nil { pending.append(neighbor); component.append(neighbor) }
                }
            }
            let xs = component.map { $0 % width }, ys = component.map { $0 / width }
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max(),
                  (4...14).contains(maxX - minX + 1), (5...16).contains(maxY - minY + 1) else { continue }
            let spans = (minY...maxY).map { y in component.filter { $0 / width == y }.map { $0 % width }.sorted() }
            // A filled triangle has solid scan lines and a nearly vertical left edge. Circular
            // Remove outlines have holes; reorder lines and the menu dots are too short.
            guard spans.allSatisfy({ !$0.isEmpty && $0.count == $0.last! - $0.first! + 1 }),
                  spans.map({ $0.first! }).max()! - spans.map({ $0.first! }).min()! <= 2,
                  spans.first!.count < spans.map(\.count).max()!,
                  spans.last!.count < spans.map(\.count).max()! else { continue }
            centers.append(CGPoint(x: Double(minX + maxX) / 2, y: Double(minY + maxY) / 2))
        }
        return centers.sorted { $0.y < $1.y }
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

    /// The text fallback keeps the normal compact Share control inside the minimum-width bar.
    func testShareStaysInsideTheBarAtTheWindowMinimum() throws {
        let linkless = playingModel(link: nil)
        for available in barWidths {
            XCTAssertEqual(available.sidebar, .rail, "\(available.name) retains the rail")
            let lines = try recognizedPlayerLines(
                bar(linkless, scale: available.scale), size: CGSize(width: available.width, height: 260))
            let linkedLines = try recognizedPlayerLines(
                bar(playingModel(link: page), scale: available.scale), size: CGSize(width: available.width, height: 260))
            XCTAssertEqual(lines.map(\.text), linkedLines.map(\.text),
                           "text sharing adds no wider warning at \(available.name)")
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
