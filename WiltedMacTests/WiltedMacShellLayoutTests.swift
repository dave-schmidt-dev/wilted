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

    func testAHiddenSidebarStaysHiddenAtEveryWidthAndFreesRoomForThePane() {
        let side = WiltedMacShellLayout.hiddenSidebarSidePaneMinimumWidth()
        XCTAssertLessThan(side, WiltedMacShellLayout.sidePaneMinimumWidth(), "no rail is left to give up")
        for width in stride(from: CGFloat(0), through: 2_500, by: 25) {
            XCTAssertEqual(WiltedMacShellLayout.resolve(windowWidth: width, sidebarVisible: false).sidebar, .hidden)
        }
        XCTAssertEqual(WiltedMacShellLayout.resolve(windowWidth: side - 1, sidebarVisible: false),
                       WiltedMacShellLayout(sidebar: .hidden, pane: .bottom))
        XCTAssertEqual(WiltedMacShellLayout.resolve(windowWidth: side, sidebarVisible: false),
                       WiltedMacShellLayout(sidebar: .hidden, pane: .side))
    }

    func testAShownSidebarIsAutomaticFullOrRailExactlyAsBefore() {
        for width in stride(from: CGFloat(400), through: 2_000, by: 5) {
            XCTAssertEqual(WiltedMacShellLayout.resolve(windowWidth: width),
                           WiltedMacShellLayout.resolve(windowWidth: width, sidebarVisible: true))
            XCTAssertNotEqual(WiltedMacShellLayout.resolve(windowWidth: width).sidebar, .hidden)
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

    func testTheButtonAndTheShortcutBothToggleTheSidebarThroughOneModelAction() throws {
        let model = WiltedMacModel(arguments: fixture, preferences: WiltedMacTestPreferences.ephemeral())
        XCTAssertEqual(model.sidebarToggleTitle, "Hide Sidebar")
        model.toggleSidebar()
        XCTAssertFalse(model.isSidebarVisible)
        XCTAssertEqual(model.sidebarToggleTitle, "Show Sidebar")
        model.toggleSidebar()
        XCTAssertTrue(model.isSidebarVisible)

        let root = try WiltedMacHeadless.viewSource("WiltedMacRootView.swift")
        XCTAssertEqual(WiltedMacHeadless.occurrences(of: "model.toggleSidebar()", in: root), 1, "the toolbar button")
        XCTAssertTrue(root.contains(".accessibilityLabel(model.sidebarToggleTitle)"), "the control is labelled")
        XCTAssertTrue(root.contains("\"wilted-sidebar-toggle\""))
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
    }

    // MARK: Hosted root: the same bar or pane on every destination

    private func rootBitmap(
        _ destination: WiltedMacNavigation, width: CGFloat, sidebarVisible: Bool = true
    ) async throws -> NSBitmapImageRep {
        let model = WiltedMacModel(
            arguments: fixture, stateDirectoryOverride: wiltedTemporaryDirectory("shell-layout"),
            preferences: WiltedMacTestPreferences.ephemeral())
        model.selectedNavigation = destination
        model.isSidebarVisible = sidebarVisible
        return try WiltedMacHeadless.render(
            WiltedMacRootView(model: model), size: CGSize(width: width, height: 700))
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

    /// Hiding the sidebar takes its column out of the window at a wide width: the detail moves left
    /// and the side pane stays where it was.
    func testHidingTheSidebarRemovesItsColumnAndKeepsThePane() async throws {
        let shown = try await rootBitmap(.larder, width: 1_200)
        let hidden = try await rootBitmap(.larder, width: 1_200, sidebarVisible: false)
        let column = NSRect(x: 0, y: 0, width: 200, height: 700)
        XCTAssertNotEqual(bytes(shown, in: column), bytes(hidden, in: column), "the sidebar column is gone")
        let pane = NSRect(x: 1_200 - 400, y: 0, width: 400, height: 700)
        XCTAssertGreaterThan(WiltedMacHeadless.distinctColorCount(in: hidden, region: pane), 3, "the pane still draws")
    }
}
