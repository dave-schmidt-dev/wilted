import AppKit
import SwiftUI
import XCTest
@testable import WiltedMac

/// One placement rule for the player and a deliberate sidebar toggle. The width bands are pure; the
/// hosted renders prove the root view draws the same bar or pane on every destination.
@MainActor
final class WiltedMacShellLayoutTests: XCTestCase {
    private let destinations: [WiltedMacNavigation] = [.feeds, .larder, .settings]
    private let fixture = ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts"]

    /// One window width inside each band, for the shown sidebar: narrow (bottom bar), side (rail
    /// and side pane) and full (labelled sidebar and side pane).
    private var bands: [(name: String, width: CGFloat, expected: WiltedMacShellLayout)] {
        let side = WiltedMacShellLayout.sidePaneMinimumWidth()
        let full = WiltedMacShellLayout.fullSidebarMinimumWidth()
        return [
            ("narrow", side - 1, WiltedMacShellLayout(sidebar: .rail, pane: .bottom)),
            ("side", side, WiltedMacShellLayout(sidebar: .rail, pane: .side)),
            ("full", full, WiltedMacShellLayout(sidebar: .full, pane: .side)),
        ]
    }

    func testFeedsLarderAndSettingsPlaceTheSameInEveryWidthBand() {
        for band in bands {
            for visible in [true, false] {
                let layouts = destinations.map {
                    WiltedMacShellLayout.resolve(for: $0, windowWidth: band.width, sidebarVisible: visible)
                }
                XCTAssertEqual(Set(layouts.map { "\($0)" }).count, 1, "\(band.name) visible=\(visible): \(layouts)")
            }
            XCTAssertEqual(
                WiltedMacShellLayout.resolve(for: .larder, windowWidth: band.width), band.expected, band.name)
        }
    }

    func testCollapsedSidebarRetainsTheExistingRailAndReservesItsSpace() {
        XCTAssertEqual(WiltedMacShellLayout.railWidth, 56, "the accepted icon rail stays the same width")
        for scale in [WiltedTheme.TextScale.standard, .large] {
            let minimum = WiltedMacShellLayout.windowMinimumWidth(scale: scale)
            let sideThreshold = WiltedMacShellLayout.sidePaneMinimumWidth(scale: scale)
            let wide = WiltedMacShellLayout.fullSidebarMinimumWidth(scale: scale) + 100
            for destination in destinations {
                for width in [minimum, sideThreshold - 1, sideThreshold, wide] {
                    let collapsed = WiltedMacShellLayout.resolve(
                        for: destination, windowWidth: width, scale: scale, sidebarVisible: false)
                    XCTAssertEqual(collapsed.sidebar, .rail, "\(destination) \(scale) width=\(width): collapse retains navigation")
                    XCTAssertEqual(collapsed.pane, width >= sideThreshold ? .side : .bottom,
                                   "the pane cannot use the 56pt reserved for navigation")
                }
                let expanded = WiltedMacShellLayout.resolve(
                    for: destination, windowWidth: wide, scale: scale, sidebarVisible: true)
                XCTAssertEqual(expanded.sidebar, .full, "the same preference expands labels when there is room")
            }
            let minimumDetailWithRail = minimum - WiltedMacShellLayout.railWidth
            XCTAssertEqual(minimumDetailWithRail,
                WiltedTheme.scaled(WiltedMacLarderLayout.listMinimumWidth, scale: scale) + WiltedMacShellLayout.slack,
                "minimum window geometry includes the rail instead of handing its width to the detail")
        }
    }

    func testSidebarToggleRetainsNavigationAndRestoresCollapsedRailBeforeExpanding() async {
        let preferences = WiltedMacTestPreferences.ephemeral()
        let directory = wiltedTemporaryDirectory("sidebar-collapse-persistence")
        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
        let width = WiltedMacShellLayout.fullSidebarMinimumWidth() + 100
        model.selectedNavigation = .feeds
        model.selectedPodcastFeedID = "collapse-fixture-feed"
        model.toggleSidebar()
        XCTAssertFalse(model.isSidebarVisible)
        XCTAssertEqual(model.selectedNavigation, .feeds)
        XCTAssertEqual(model.selectedPodcastFeedID, "collapse-fixture-feed")
        XCTAssertEqual(WiltedMacShellLayout.resolve(
            for: model.selectedNavigation, windowWidth: width, sidebarVisible: model.isSidebarVisible).sidebar, .rail)

        let restored = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
        XCTAssertFalse(restored.isSidebarVisible, "the existing saved false preference restores a collapsed rail")
        XCTAssertEqual(restored.selectedNavigation, .feeds)
        XCTAssertEqual(WiltedMacShellLayout.resolve(
            for: restored.selectedNavigation, windowWidth: width, sidebarVisible: restored.isSidebarVisible).sidebar, .rail)
        restored.toggleSidebar()
        XCTAssertTrue(restored.isSidebarVisible)
        XCTAssertEqual(restored.selectedNavigation, .feeds)
        XCTAssertEqual(WiltedMacShellLayout.resolve(
            for: restored.selectedNavigation, windowWidth: width, sidebarVisible: restored.isSidebarVisible).sidebar, .full)
        XCTAssertTrue(preferences.bool(forKey: WiltedMacModel.sidebarVisiblePreferenceKey))
        await restored.close()
        await model.close()
    }

    func testACollapsedSidebarRetainsTheRailAtEveryWidthAndReservesRoomForIt() {
        let side = WiltedMacShellLayout.sidePaneMinimumWidth()
        for width in stride(from: CGFloat(0), through: 2_500, by: 25) {
            XCTAssertEqual(WiltedMacShellLayout.resolve(windowWidth: width, sidebarVisible: false).sidebar, .rail)
        }
        XCTAssertEqual(WiltedMacShellLayout.resolve(windowWidth: side - 1, sidebarVisible: false),
                       WiltedMacShellLayout(sidebar: .rail, pane: .bottom))
        XCTAssertEqual(WiltedMacShellLayout.resolve(windowWidth: side, sidebarVisible: false),
                       WiltedMacShellLayout(sidebar: .rail, pane: .side))
    }

    func testAShownSidebarIsAutomaticFullOrRailExactlyAsBefore() {
        for width in stride(from: CGFloat(400), through: 2_000, by: 5) {
            XCTAssertEqual(WiltedMacShellLayout.resolve(windowWidth: width),
                           WiltedMacShellLayout.resolve(windowWidth: width, sidebarVisible: true))
            XCTAssertTrue([WiltedMacSidebarMode.full, .rail].contains(WiltedMacShellLayout.resolve(windowWidth: width).sidebar))
        }
    }

    func testSidebarVisibilityPersistsAcrossAFreshModel() {
        // A fixture launch replaces the preferences with its own, so this uses a plain launch.
        let preferences = WiltedMacTestPreferences.ephemeral()
        let first = WiltedMacModel(arguments: [], preferences: preferences)
        XCTAssertTrue(first.isSidebarVisible, "shown by default")
        first.isSidebarVisible = false
        XCTAssertFalse(WiltedMacModel(arguments: [], preferences: preferences).isSidebarVisible)
        first.isSidebarVisible = true
        XCTAssertTrue(WiltedMacModel(arguments: [], preferences: preferences).isSidebarVisible)
    }

    func testTheButtonAndTheShortcutBothToggleTheSidebarThroughOneModelAction() async throws {
        let model = WiltedMacModel(arguments: fixture,
            stateDirectoryOverride: wiltedTemporaryDirectory("shell-layout-toggle"),
            preferences: WiltedMacTestPreferences.ephemeral())
        await model.fixtureInstallTask?.value
        await model.fixturePodcastInstallTask?.value
        await model.waitForLifetimeStatisticsForTesting()
        do {
            XCTAssertEqual(model.sidebarToggleTitle, "Collapse Sidebar")
            model.toggleSidebar()
            XCTAssertFalse(model.isSidebarVisible)
            XCTAssertEqual(model.sidebarToggleTitle, "Expand Sidebar")
            model.toggleSidebar()
            XCTAssertTrue(model.isSidebarVisible)

            let root = try WiltedMacHeadless.viewSource("WiltedMacRootView.swift")
            XCTAssertEqual(WiltedMacHeadless.occurrences(of: "model.toggleSidebar()", in: root), 1, "the toolbar button")
            XCTAssertTrue(root.contains(".accessibilityLabel(model.sidebarToggleTitle)"), "the control is labelled")
            XCTAssertTrue(root.contains("\"wilted-sidebar-toggle\""))
            XCTAssertTrue(root.contains("var sidebarToggleContent: some View"))
            XCTAssertTrue(root.contains("var wordmarkContent: some View"))
            XCTAssertEqual(WiltedMacHeadless.occurrences(of: "WiltedWordmark(height: 16)", in: root), 1)
            XCTAssertEqual(WiltedMacHeadless.occurrences(of: "wordmarkContent", in: root), 3,
                           "both availability branches use the shipping content seam")
            let sidebar = try WiltedMacHeadless.viewSource("WiltedMacSidebar.swift")
            XCTAssertTrue(sidebar.contains("func row(_ destination: WiltedMacNavigation) -> some View"))
            XCTAssertFalse(sidebar.contains("private func row("))
            let app = try String(
                contentsOf: WiltedMacHeadless.sourceRoot().appendingPathComponent("WiltedMac/WiltedMacApp.swift"),
                encoding: .utf8)
            XCTAssertTrue(app.contains("CommandGroup(replacing: .sidebar)"), "the system command has no split view to act on")
            XCTAssertTrue(app.contains("model.toggleSidebar()"))
            XCTAssertTrue(app.contains(".keyboardShortcut(\"s\", modifiers: [.control, .command])"), "⌃⌘S")
            XCTAssertFalse(app.contains("SidebarCommands()"))
            XCTAssertFalse(root.contains("NavigationSplitView {") || root.contains("NavigationSplitView("), "the custom column stays")
            let sidebarKey = WiltedMacModel.sidebarVisiblePreferenceKey
            XCTAssertEqual(sidebarKey, "wilted.navigation.sidebar.visible")
        } catch {
            await model.close()
            throw error
        }
        await model.close()
    }

    // MARK: Hosted root: the same bar or pane on every destination

    private func rootBitmap(
        _ destination: WiltedMacNavigation, width: CGFloat, sidebarVisible: Bool = true,
        appearance: ColorScheme = .light, textScale: WiltedTheme.TextScale? = nil
    ) async throws -> NSBitmapImageRep {
        let model = WiltedMacModel(
            arguments: fixture, stateDirectoryOverride: wiltedTemporaryDirectory("shell-layout"),
            preferences: WiltedMacTestPreferences.ephemeral())
        await model.fixtureInstallTask?.value
        await model.fixturePodcastInstallTask?.value
        await model.waitForLifetimeStatisticsForTesting()
        if let textScale { model.setTextScale(textScale) }
        model.selectedNavigation = destination
        model.isSidebarVisible = sidebarVisible
        do {
            let bitmap = try WiltedMacHeadless.render(
                WiltedMacRootView(model: model).environment(\.colorScheme, appearance), size: CGSize(width: width, height: 700))
            await model.close()
            return bitmap
        } catch {
            await model.close()
            throw error
        }
    }

    private func bytes(_ bitmap: NSBitmapImageRep, in rect: NSRect) -> [UInt8] {
        guard let data = bitmap.bitmapData else { return [] }
        var out: [UInt8] = []
        for y in Int(rect.minY)..<min(Int(rect.maxY), bitmap.pixelsHigh) {
            let row = data + y * bitmap.bytesPerRow
            for x in Int(rect.minX)..<min(Int(rect.maxX), bitmap.pixelsWide) {
                out.append(contentsOf: (0..<bitmap.samplesPerPixel).map { row[x * bitmap.samplesPerPixel + $0] })
            }
        }
        return out
    }

    func testTheSidePaneIsPixelIdenticalOnEveryDestinationAtWideWidth() async throws {
        var panes: [[UInt8]] = []
        for destination in destinations {
            let bitmap = try await rootBitmap(destination, width: 1_200)
            let region = NSRect(x: 1_200 - 400, y: 0, width: 400, height: 700)
            XCTAssertGreaterThan(WiltedMacHeadless.distinctColorCount(in: bitmap, region: region), 3,
                                 "\(destination): the side pane drew")
            panes.append(bytes(bitmap, in: region))
        }
        XCTAssertTrue(panes.dropFirst().allSatisfy { $0 == panes[0] }, "one pane, same place, every destination")
    }

    func testTheBottomBarIsPixelIdenticalOnEveryDestinationAtNarrowWidth() async throws {
        var bars: [[UInt8]] = []
        for destination in destinations {
            let bitmap = try await rootBitmap(destination, width: 900)
            // The bar is the strip under the rail-wide sidebar column, below the destination content.
            let bar = NSRect(x: 64, y: 700 - 46, width: 900 - 64, height: 46)
            XCTAssertGreaterThan(WiltedMacHeadless.distinctColorCount(in: bitmap, region: bar), 3,
                                 "\(destination): the bottom bar drew")
            bars.append(bytes(bitmap, in: bar))
        }
        XCTAssertTrue(bars.dropFirst().allSatisfy { $0 == bars[0] }, "one bar, same place, every destination")
    }

    /// Collapse gives the detail the labelled column's surplus width while
    /// retaining the navigation rail and the side player's placement.
    func testCollapsingTheSidebarKeepsItsRailAndPaneAtWideWidth() async throws {
        let iconModel = await WiltedMacHeadless.model(self, fixture)
        let scale = iconModel.textScale
        let fullThreshold = WiltedMacShellLayout.fullSidebarMinimumWidth(scale: scale)
        let width = fullThreshold + 100
        XCTAssertGreaterThanOrEqual(width, fullThreshold, "the render viewport must permit full labels at the actual model scale")
        let layout = WiltedMacShellLayout.resolve(windowWidth: width, scale: scale, sidebarVisible: false)
        XCTAssertEqual(layout.sidebar, .rail)
        XCTAssertEqual(layout.pane, .side)
        XCTAssertEqual(WiltedMacShellLayout.resolve(windowWidth: width, scale: scale).sidebar, .full)
        iconModel.isSidebarVisible = false
        do {
            for appearance in [ColorScheme.light, .dark] {
                let expanded = try await rootBitmap(.larder, width: width, appearance: appearance, textScale: scale)
                let collapsed = try await rootBitmap(.larder, width: width, sidebarVisible: false, appearance: appearance, textScale: scale)
                XCTAssertEqual(collapsed.pixelsWide, Int(width))
                let column = NSRect(x: 0, y: 0, width: WiltedTheme.scaled(WiltedMacShellLayout.sidebarIdealWidth, scale: scale), height: 700)
                XCTAssertNotEqual(bytes(expanded, in: column), bytes(collapsed, in: column), "labels collapse but navigation retains its rail")
                let pane = NSRect(x: width - 400, y: 0, width: 400, height: 700)
                XCTAssertGreaterThan(WiltedMacHeadless.distinctColorCount(in: collapsed, region: pane), 3, "the pane still draws")
                XCTAssertEqual(bytes(expanded, in: pane), bytes(collapsed, in: pane), "collapse does not change the side pane")
                for (mode, bitmap) in [("expanded", expanded), ("collapsed", collapsed)] {
                    let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
                                                   uniformTypeIdentifier: "public.png")
                    attachment.name = "sidebar-\(mode)-wide-\(appearance == .dark ? "dark" : "light")"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
                // Native List rows do not paint offscreen. Use the accepted shipping
                // row-content seam to prove glyphs separately from root geometry.
                let sidebar = WiltedMacSidebar(model: iconModel, mode: layout.sidebar) {
                    iconModel.selectedNavigation = $0
                }
                for destination in destinations {
                    sidebar.onSelect(destination)
                    XCTAssertEqual(iconModel.selectedNavigation, destination)
                    let row = sidebar.row(destination)
                        .frame(width: WiltedMacShellLayout.railWidth, height: 44)
                        .background(WiltedTheme.color(.page, scheme: appearance))
                        .environment(\.colorScheme, appearance)
                        .environment(\.wiltedTextScale, iconModel.textScale)
                    let bitmap = try WiltedMacHeadless.render(row,
                        size: CGSize(width: WiltedMacShellLayout.railWidth, height: 44))
                    XCTAssertEqual(bitmap.pixelsWide, 56)
                    let glyph = NSRect(x: 18, y: 9, width: 20, height: 26)
                    XCTAssertGreaterThan(WiltedMacHeadless.distinctColorCount(in: bitmap, region: glyph), 4,
                                         "\(destination): the collapsed shipping icon glyph painted")
                    let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
                                                   uniformTypeIdentifier: "public.png")
                    attachment.name = "sidebar-collapsed-icon-\(destination.rawValue)-\(appearance == .dark ? "dark" : "light")"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
        } catch {
            await iconModel.close()
            throw error
        }
        await iconModel.close()
    }
}
