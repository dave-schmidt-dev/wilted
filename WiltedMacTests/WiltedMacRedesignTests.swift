import AppKit
import SwiftUI
import XCTest
import WiltedDomain
@testable import WiltedMac

/// The Mac redesign's pure logic: when the Larder gets two panes, what a row
/// says about progress, which transcript line a tap or the clock selects, and
/// that the app accent is Wilted's leaf rather than the system blue.
@MainActor
final class WiltedMacRedesignTests: XCTestCase {
    // MARK: Pane split

    func testPaneStaysInItsBandAndTheListTakesTheRest() {
        var previousList: CGFloat = 0
        let from = WiltedMacLarderLayout.listMinimumWidth + WiltedMacLarderLayout.paneWidth.lowerBound + 1
        for width in stride(from: from, through: 3_000, by: 50) {
            let pane = WiltedMacLarderLayout.paneColumnWidth(detailWidth: width)
            let list = WiltedMacLarderLayout.listColumnWidth(detailWidth: width)
            XCTAssertGreaterThanOrEqual(pane, 420)
            XCTAssertLessThanOrEqual(pane, 480)
            XCTAssertEqual(pane + list + 1, width, accuracy: 0.001, "no width is lost between the two")
            XCTAssertGreaterThanOrEqual(list, WiltedMacLarderLayout.listMinimumWidth)
            XCTAssertGreaterThanOrEqual(list, previousList, "extra width never shrinks the list")
            previousList = list
        }
        XCTAssertEqual(WiltedMacLarderLayout.paneColumnWidth(detailWidth: 3_000), 480,
                       "a very wide window does not widen the pane past its cap")
    }

    // MARK: Rail and bottom bar follow the window width

    func testNarrowingGivesUpTheSidebarBeforeThePane() {
        let full = WiltedMacShellLayout.fullSidebarMinimumWidth()
        let side = WiltedMacShellLayout.sidePaneMinimumWidth()
        XCTAssertEqual(full, 200 + 480 + 420 + 1 + 40, "sidebar + list + pane + divider + slack")
        XCTAssertEqual(side, 56 + 480 + 420 + 1 + 40, "rail + list + pane + divider + slack")
        XCTAssertLessThan(side, full, "the rail comes before the bottom bar")
        XCTAssertEqual(WiltedMacShellLayout.resolve(windowWidth: full),
                       WiltedMacShellLayout(sidebar: .full, pane: .side))
        XCTAssertEqual(WiltedMacShellLayout.resolve(windowWidth: full - 1),
                       WiltedMacShellLayout(sidebar: .rail, pane: .side))
        XCTAssertEqual(WiltedMacShellLayout.resolve(windowWidth: side),
                       WiltedMacShellLayout(sidebar: .rail, pane: .side))
        XCTAssertEqual(WiltedMacShellLayout.resolve(windowWidth: side - 1),
                       WiltedMacShellLayout(sidebar: .rail, pane: .bottom))
        XCTAssertEqual(WiltedMacShellLayout.resolve(windowWidth: 0),
                       WiltedMacShellLayout(sidebar: .rail, pane: .bottom),
                       "nothing disappears at any width")
    }

    func testWideningReversesBothInOrder() {
        var seen: [WiltedMacShellLayout] = []
        for width in stride(from: CGFloat(500), through: 2_000, by: 10) {
            let layout = WiltedMacShellLayout.resolve(windowWidth: width)
            if seen.last != layout { seen.append(layout) }
        }
        XCTAssertEqual(seen, [
            WiltedMacShellLayout(sidebar: .rail, pane: .bottom),
            WiltedMacShellLayout(sidebar: .rail, pane: .side),
            WiltedMacShellLayout(sidebar: .full, pane: .side),
        ])
    }

    /// At every text size and width the list keeps its minimum, and the pane
    /// is beside it only when both fit: the rail never costs the list room.
    func testTheListAlwaysKeepsItsMinimumAtEveryTextSize() {
        for scale in WiltedTheme.TextScale.allCases {
            let listMinimum = WiltedTheme.scaled(WiltedMacLarderLayout.listMinimumWidth, scale: scale)
            let windowMinimum = WiltedMacShellLayout.windowMinimumWidth(scale: scale)
            XCTAssertGreaterThanOrEqual(windowMinimum, WiltedMacShellLayout.railWidth + listMinimum)
            var rankOfPrevious = 0
            for width in stride(from: windowMinimum, through: 3_000, by: 5) {
                let layout = WiltedMacShellLayout.resolve(windowWidth: width, scale: scale)
                let sidebarWidth = layout.sidebar == .rail
                    ? WiltedMacShellLayout.railWidth
                    : WiltedTheme.scaled(WiltedMacShellLayout.sidebarIdealWidth, scale: scale)
                let pane = layout.pane == .side ? WiltedMacLarderLayout.paneWidth.lowerBound + 1 : 0
                XCTAssertGreaterThanOrEqual(width - sidebarWidth - pane, listMinimum,
                                            "\(scale) \(width)")
                let rank = (layout.sidebar == .full ? 1 : 0) + (layout.pane == .side ? 1 : 0)
                XCTAssertGreaterThanOrEqual(rank, rankOfPrevious, "widening never takes an area away")
                rankOfPrevious = rank
            }
        }
    }

    func testEnlargedTextRaisesBothThresholds() {
        XCTAssertGreaterThan(WiltedMacShellLayout.fullSidebarMinimumWidth(scale: .largest),
                             WiltedMacShellLayout.fullSidebarMinimumWidth(scale: .standard))
        XCTAssertGreaterThan(WiltedMacShellLayout.sidePaneMinimumWidth(scale: .largest),
                             WiltedMacShellLayout.sidePaneMinimumWidth(scale: .standard))
        XCTAssertGreaterThan(WiltedMacShellLayout.windowMinimumWidth(scale: .largest),
                             WiltedMacShellLayout.windowMinimumWidth(scale: .standard))
    }

    /// Neither side area has a way to be hidden: the sidebar is a column of
    /// the root rather than a split-view column (which cannot change width at
    /// run time, nor be kept from hiding), so there is no toggle to remove.
    func testNothingCanHideTheRailOrThePane() throws {
        let views = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("WiltedMac/Views")
        let root = try String(contentsOf: views.appendingPathComponent("WiltedMacRootView.swift"), encoding: .utf8)
        let menu = try String(contentsOf: views.appendingPathComponent("WiltedMacMenuView.swift"), encoding: .utf8)
        XCTAssertFalse(root.contains("NavigationSplitView("))
        XCTAssertTrue(root.contains(".frame(width: sidebarColumnWidth)"))
        XCTAssertTrue(root.contains(".frame(minWidth: WiltedMacShellLayout.windowMinimumWidth("))
        XCTAssertFalse(menu.contains("Hide Now Playing"))
        XCTAssertTrue(menu.contains("paneMode: WiltedMacPaneMode"))
    }

    func testFixtureWindowWidthIsReadOnlyFromAFixtureLaunch() {
        let fixture = ["app", "--wilted-ui-fixture-larder-demo", WiltedMacFixtureWindowWidth.argument, "900"]
        XCTAssertEqual(WiltedMacFixtureWindowWidth.width(arguments: fixture), 900)
        XCTAssertNil(WiltedMacFixtureWindowWidth.width(arguments: ["app", WiltedMacFixtureWindowWidth.argument, "900"]),
                     "a normal launch never reads it")
        XCTAssertNil(WiltedMacFixtureWindowWidth.width(
            arguments: ["app", "--wilted-ui-fixture-larder-demo", WiltedMacFixtureWindowWidth.argument, "-3"]))
        XCTAssertNil(WiltedMacFixtureWindowWidth.width(
            arguments: ["app", "--wilted-ui-fixture-larder-demo", WiltedMacFixtureWindowWidth.argument]))
    }

    // MARK: Watermark

    func testPhoneWatermarkKeepsItsSize() {
        XCTAssertEqual(LibraryWatermark.phoneSize, 380)
        XCTAssertEqual(LibraryWatermark.phoneOffset, CGSize(width: 80, height: 90))
    }

    func testWindowedWatermarkIsTwiceTheSizeAndNeverClipped() {
        XCTAssertEqual(LibraryWatermark.windowedSize, 2 * LibraryWatermark.phoneSize)
        let roomy = LibraryWatermark.fittedSize(in: CGSize(width: 1_400, height: 1_400))
        XCTAssertEqual(roomy, LibraryWatermark.windowedSize, "a large area gets the full size")
        for area in [CGSize(width: 900, height: 700), CGSize(width: 600, height: 500),
                     CGSize(width: 480, height: 300), CGSize(width: 200, height: 120)] {
            let side = LibraryWatermark.fittedSize(in: area)
            let extent = side * LibraryWatermark.rotatedExtent
            XCTAssertLessThanOrEqual(extent + LibraryWatermark.fittingInset.trailing, area.width + 0.001)
            XCTAssertLessThanOrEqual(extent + LibraryWatermark.fittingInset.bottom, area.height + 0.001)
        }
        // Kept clear of a head above the rows: the same room, less the head.
        let tall = CGSize(width: 1_400, height: 1_000)
        XCTAssertLessThan(LibraryWatermark.fittedSize(in: tall, topInset: 300),
                          LibraryWatermark.fittedSize(in: tall))
        XCTAssertEqual(LibraryWatermark.fittedSize(in: CGSize(width: 900, height: 600), topInset: 900), 0)
        XCTAssertEqual(LibraryWatermark.fittedSize(in: .zero), 0, "no room draws nothing rather than a negative size")
    }

    // MARK: Pane state survives the layout switch

    func testPaneStateIsReaderOwnedAndOnlyAnEpisodeChangeResetsFollowing() {
        var state = WiltedMacPaneState()
        state.tab = .notes
        state.followsPlayback = false
        // The Larder owns this value, so resolving the layout around it --
        // two-pane, stacked, two-pane again -- never reaches it.
        for width in [1_600, 700, 1_600] as [CGFloat] {
            _ = WiltedMacShellLayout.resolve(windowWidth: width)
        }
        XCTAssertEqual(state.tab, .notes)
        XCTAssertFalse(state.followsPlayback)
        state.episodeChanged()
        XCTAssertTrue(state.followsPlayback, "a new episode starts at its own line")
        XCTAssertEqual(state.tab, .notes, "the reader's tab stays")
    }

    /// Narrow, open Notes in the full-window player, collapse, widen: the pane
    /// opens on Notes. The state's owner takes the collapse, since the pane is
    /// not mounted while the window is narrow.
    func testCollapsingTheFullWindowPlayerCarriesItsSectionToThePane() throws {
        var state = WiltedMacPaneState()
        state.followsPlayback = false
        state.collapsed(to: .notes)
        XCTAssertEqual(state.tab, .notes)
        XCTAssertTrue(state.followsPlayback)
        state.collapsed(to: .transcript)
        XCTAssertEqual(state.tab, .transcript)
        let views = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("WiltedMac/Views")
        let menu = try String(contentsOf: views.appendingPathComponent("WiltedMacMenuView.swift"), encoding: .utf8)
        XCTAssertTrue(menu.contains("paneState.collapsed(to: section)"))
    }

    /// The state's owner, which outlives the pane, watches the episode; the
    /// pane (unmounted when narrow) must not be the only observer.
    func testEpisodeChangeIsObservedByTheStateOwnerNotThePane() throws {
        let views = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("WiltedMac/Views")
        let menu = try String(contentsOf: views.appendingPathComponent("WiltedMacMenuView.swift"), encoding: .utf8)
        let pane = try String(contentsOf: views.appendingPathComponent("WiltedMacNowPlayingPane.swift"), encoding: .utf8)
        XCTAssertTrue(menu.contains("paneState.episodeChanged()"))
        XCTAssertFalse(pane.contains("state.episodeChanged()"))
    }

    func testTabChangeResumesFollowing() {
        var state = WiltedMacPaneState()
        state.followsPlayback = false
        state.tab = .notes
        state.tabChanged()
        XCTAssertTrue(state.followsPlayback)
        XCTAssertEqual(state.tab, .notes)
    }

    /// Both apps share one search prompt, short enough for the Mac field.
    func testSearchPromptIsTheSameOnBothApps() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for path in ["WiltedMac/Views/WiltedMacMenuView.swift", "WiltediOS/Library/LibraryListView.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            XCTAssertTrue(source.contains("prompt: \"Search episodes\""), path)
        }
    }

    /// The list is one view in both compositions, so its scroll position is
    /// not rebuilt at the threshold. Structural: asserts the Larder no longer
    /// switches between two separate list subtrees.
    func testLarderKeepsOneListViewAcrossTheLayoutSwitch() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("WiltedMac/Views/WiltedMacMenuView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(source.components(separatedBy: "WiltedMacDestination(").count - 1, 1,
                       "one list destination, not one per layout")
        XCTAssertFalse(source.contains("switch paneMode"))
        XCTAssertTrue(source.contains("WiltedMacNowPlayingPane(model: model, state: $paneState)"))
    }

    // MARK: Row progress

    func testProgressNeedsAStartedUnfinishedEpisodeOfKnownLength() {
        XCTAssertNil(WiltedMacEpisodeProgress(positionSeconds: 0, durationSeconds: 600, isPlayed: false))
        XCTAssertNil(WiltedMacEpisodeProgress(positionSeconds: 100, durationSeconds: 600, isPlayed: true))
        XCTAssertNil(WiltedMacEpisodeProgress(positionSeconds: 100, durationSeconds: nil, isPlayed: false))
        XCTAssertNil(WiltedMacEpisodeProgress(positionSeconds: 100, durationSeconds: 0, isPlayed: false))
        XCTAssertNil(WiltedMacEpisodeProgress(positionSeconds: .nan, durationSeconds: 600, isPlayed: false))
    }

    func testProgressFractionAndTimeLeftMatchTheCarPlayWording() throws {
        let partway = try XCTUnwrap(
            WiltedMacEpisodeProgress(positionSeconds: 150, durationSeconds: 600, isPlayed: false))
        XCTAssertEqual(partway.fraction, 0.25, accuracy: 0.0001)
        XCTAssertEqual(partway.timeLeftLabel, "07:30 left")
        let long = try XCTUnwrap(
            WiltedMacEpisodeProgress(positionSeconds: 600, durationSeconds: 7_200, isPlayed: false))
        XCTAssertEqual(long.timeLeftLabel, "1:50:00 left")
    }

    func testProgressClampsAPositionPastTheEnd() throws {
        let over = try XCTUnwrap(
            WiltedMacEpisodeProgress(positionSeconds: 700, durationSeconds: 600, isPlayed: false))
        XCTAssertEqual(over.fraction, 1)
        XCTAssertEqual(over.timeLeftLabel, "00:00 left")
    }

    // MARK: Transcript mapping

    private let transcript = WiltedMacTranscript(
        availability: .available, text: "a b c",
        cues: [
            WiltedMacTranscriptCue(id: 0, startSeconds: 2, endSeconds: 4, text: "a"),
            WiltedMacTranscriptCue(id: 1, startSeconds: 4, endSeconds: 6, text: "b"),
            WiltedMacTranscriptCue(id: 2, startSeconds: 6, endSeconds: 9, text: "c"),
        ],
        timingSource: "synced"
    )

    func testTappedLineSeeksToItsOwnCue() {
        XCTAssertEqual(transcript.cue(forLineID: 1)?.startSeconds, 4)
        XCTAssertEqual(transcript.cue(forLineID: 2)?.text, "c")
    }

    func testStaleLineSeeksNowhere() {
        XCTAssertNil(transcript.cue(forLineID: 3), "a line from a longer, replaced transcript must not trap")
        XCTAssertNil(transcript.cue(forLineID: -1))
    }

    func testCurrentLineFollowsThePlayheadForThePaneToo() {
        XCTAssertNil(transcript.cueIndex(at: 1))
        XCTAssertEqual(transcript.cueIndex(at: 4.5), 1)
        XCTAssertEqual(transcript.cueIndex(at: 100), 2)
    }

    // MARK: Scrubber labels

    func testScrubberLabels() {
        XCTAssertEqual(WiltedMacScrubberLabels.elapsed(65), "1:05")
        XCTAssertEqual(WiltedMacScrubberLabels.remaining(position: 65, duration: 125), "-1:00")
        XCTAssertEqual(WiltedMacScrubberLabels.remaining(position: 500, duration: 125), "-0:00")
    }

    // MARK: Accent

    /// The accent asset must be the theme's leaf in both appearances, so an
    /// unthemed control and the sidebar never fall back to system blue.
    func testAccentColorAssetIsTheThemeLeaf() throws {
        let color = try XCTUnwrap(NSColor(named: "AccentColor", bundle: Bundle(for: WiltedMacModel.self)),
                                  "AccentColor.colorset missing from the app bundle")
        for (name, scheme) in [(NSAppearance.Name.aqua, ColorScheme.light), (.darkAqua, .dark)] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            var resolved: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                resolved = color.usingColorSpace(.sRGB)
            }
            let rgb = try XCTUnwrap(resolved)
            let hex = WiltedTheme.hex(for: .wiltedLeaf, scheme: scheme)
            XCTAssertEqual(rgb.redComponent, Double((hex >> 16) & 0xFF) / 255, accuracy: 0.003, "\(scheme) red")
            XCTAssertEqual(rgb.greenComponent, Double((hex >> 8) & 0xFF) / 255, accuracy: 0.003, "\(scheme) green")
            XCTAssertEqual(rgb.blueComponent, Double(hex & 0xFF) / 255, accuracy: 0.003, "\(scheme) blue")
        }
    }

    func testSidebarRowsNameLeafForSelectionAndNeverTheSystemAccent() {
        XCTAssertEqual(WiltedMacSidebarStyle.iconToken(isSelected: true), .wiltedLeaf)
        XCTAssertEqual(WiltedMacSidebarStyle.iconToken(isSelected: false), .secondaryText)
        XCTAssertEqual(WiltedMacSidebarStyle.titleToken(isSelected: true), .primaryText)
        XCTAssertEqual(WiltedMacSidebarStyle.titleToken(isSelected: false), .secondaryText)
    }
    // MARK: Parity with iOS

    /// The sidebar uses iOS's symbols: the Larder is the larder, feeds are the
    /// broccoli, Settings keeps the system gear.
    func testSidebarSymbolsMatchIOS() {
        XCTAssertEqual(WiltedMacNavigation.menu.symbolName, WiltedNavigation.library.symbolName)
        XCTAssertEqual(WiltedMacNavigation.menu.symbolName, WiltedSymbol.larder.rawValue)
        XCTAssertEqual(WiltedMacNavigation.feeds.symbolName, WiltedSymbol.broccoli.rawValue)
        XCTAssertEqual(WiltedMacNavigation.settings.symbolName, WiltedNavigation.settings.symbolName)
    }

    /// The pane's artwork is a small cover, not the page's centerpiece.
    func testPaneArtworkIsHalfTheOriginalSide() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("WiltedMac/Views/WiltedMacNowPlayingPane.swift"),
            encoding: .utf8)
        XCTAssertTrue(source.contains("WiltedTheme.scaled(110, scale: model.textScale)"))
        XCTAssertFalse(source.contains("size: 220"))
    }
}
