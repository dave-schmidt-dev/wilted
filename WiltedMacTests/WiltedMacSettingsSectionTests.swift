import AppKit
import SwiftUI
import XCTest
import WiltedDomain
import WiltedLibrary
@testable import WiltedMac

@MainActor
final class WiltedMacSettingsSectionTests: XCTestCase {
    func testCurrentAndHistoricalDeviceRowsKeepTheirOptionsMenus() throws {
        let announcedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let entry = try ItemID(rawValue: "fixture-episode")
        let request = LibraryMediaRequestStatus(
            intentID: "fixture-request", entryID: entry, stage: .received, updatedAt: announcedAt)
        let devices = [
            WiltedMacLinkedDevice(deviceID: "fixture-a", kind: "iPhone", isLinked: true,
                                  inFlight: [], lastAnnouncedAt: announcedAt),
            WiltedMacLinkedDevice(deviceID: "fixture-b", kind: "iPad", isLinked: false,
                                  inFlight: [], lastAnnouncedAt: announcedAt),
            WiltedMacLinkedDevice(deviceID: "fixture-active", kind: nil, isLinked: false, inFlight: [request]),
            WiltedMacLinkedDevice(deviceID: "fixture-history", kind: nil, isLinked: false, inFlight: [])
        ]
        let rows = WiltedMacLibrarySyncStatus.deviceRows(devices)
            + WiltedMacLibrarySyncStatus.unidentifiedRequestRows(devices)
            + WiltedMacLibrarySyncStatus.earlierSyncActivityRows(devices)
        XCTAssertEqual(rows.map(\.id), ["fixture-a", "fixture-b", "fixture-active", "fixture-history"])

        for row in rows {
            let view = WiltedMacDeviceDownloadsRow(row: row, macEnabled: true, onStop: {})
            let size = CGSize(width: 400, height: 40)
            // Only the ellipsis responds to imageScale. Compare its trailing slot across renders.
            func menuPixels(at scale: Image.Scale) throws -> [NSColor?] {
                let bitmap = try WiltedMacHeadless.render(view.imageScale(scale).background(Color.white), size: size)
                return (0..<bitmap.pixelsHigh).flatMap { y in
                    (bitmap.pixelsWide - 28..<bitmap.pixelsWide).map { bitmap.colorAt(x: $0, y: y) }
                }
            }
            let small = try menuPixels(at: .small)
            let large = try menuPixels(at: .large)
            XCTAssertFalse(small == large, "Missing menu symbol on \(row.label)")
        }
    }

    func testDeviceToggleOnlyStopsAnEnabledDevice() {
        for stopped in [false, true] {
            for macEnabled in [false, true] {
                let row = WiltedMacLibrarySyncStatus.DeviceRow(
                    id: "fixture", label: "Device", value: "Linked", isDirectDownloadsStopped: stopped)
                var stops = 0
                let menu = WiltedMacDeviceDownloadsMenu(row: row, macEnabled: macEnabled) { stops += 1 }
                XCTAssertEqual(menu.downloads.wrappedValue, !stopped)
                XCTAssertEqual(menu.canStop, macEnabled && !stopped)
                menu.downloads.wrappedValue = true
                XCTAssertEqual(stops, 0)
                menu.downloads.wrappedValue = false
                XCTAssertEqual(stops, macEnabled && !stopped ? 1 : 0)
            }
        }
    }

    private func settingsModel(preferences: UserDefaults = WiltedMacTestPreferences.ephemeral()) -> WiltedMacModel {
        WiltedMacModel(arguments: [], stateDirectoryOverride: wiltedTemporaryDirectory("settings-navigation"),
                       preferences: preferences)
    }

    func testLegacyAnchorsAndAllNewSelectionsRestoreAcrossLaunches() {
        let preferences = WiltedMacTestPreferences.ephemeral()
        func launch() -> WiltedMacModel { settingsModel(preferences: preferences) }
        let first = launch()
        XCTAssertEqual(first.settingsSection, .general)
        XCTAssertEqual(first.settingsTab, .listening)
        XCTAssertEqual(WiltedMacSettingsSection.allCases.map(\.title),
                       ["General", "New episodes", "Preparing", "Ads", "Providers", "Reports", "Devices", "About"])
        let legacy: [String: WiltedMacSettingsSection] = [
            "appearance": .general, "statistics": .about, "automation": .newEpisodes,
            "ad-finding": .ads, "ad-feedback": .ads, "reports": .reports, "sync": .devices
        ]
        for (suffix, section) in legacy {
            first.scrollAnchor(for: .settings).wrappedValue = "settings-" + suffix
            XCTAssertEqual(launch().settingsSection, section)
        }
        for section in WiltedMacSettingsSection.allCases {
            first.settingsSection = section
            XCTAssertEqual(launch().settingsSection, section)
        }

        for tab in WiltedMacSettingsTab.allCases {
            first.settingsTab = tab
            XCTAssertEqual(first.scrollAnchor(for: .settings).wrappedValue, tab.sections[0].rawValue)
            XCTAssertEqual(launch().settingsTab, tab)

            first.scrollAnchor(for: .settings).wrappedValue = tab.rawValue
            let restored = launch()
            XCTAssertEqual(restored.settingsTab, tab)
            XCTAssertEqual(restored.settingsScrollPosition.wrappedValue, tab.sections[0].rawValue)
        }
    }

    func testTabsContainEverySectionOnceAndInTheChosenOrder() {
        let tabs = WiltedMacSettingsTab.allCases
        XCTAssertEqual(tabs.map(\.id), ["listening", "feeds-reports", "ads-providers", "library-sync"])
        XCTAssertEqual(tabs.map(\.title), ["Listening", "Feeds & Reports", "Ads & Providers", "Library & Sync"])

        let sections = tabs.flatMap(\.sections)
        XCTAssertEqual(sections.count, WiltedMacSettingsSection.allCases.count)
        XCTAssertEqual(Set(sections), Set(WiltedMacSettingsSection.allCases))

        XCTAssertEqual(tabs[0].sections, [.general, .preparing])
        XCTAssertEqual(tabs[1].sections, [.newEpisodes, .reports])
        XCTAssertEqual(tabs[2].sections, [.ads, .providers])
        XCTAssertEqual(tabs[3].sections, [.devices, .about])
    }

    func testLegacyAndSectionAnchorsSelectTheirContainingTab() {
        let preferences = WiltedMacTestPreferences.ephemeral()
        let model = settingsModel(preferences: preferences)
        let legacyAnchors: [(String, WiltedMacSettingsTab)] = [
            ("settings-appearance", .listening), ("settings-automation", .feedsAndReports),
            ("settings-ad-finding", .adsAndProviders), ("settings-ad-feedback", .adsAndProviders),
            ("settings-reports", .feedsAndReports), ("settings-sync", .libraryAndSync),
            ("settings-statistics", .libraryAndSync)
        ]
        for (anchor, tab) in legacyAnchors {
            model.scrollAnchor(for: .settings).wrappedValue = anchor
            XCTAssertEqual(model.settingsTab, tab, anchor)
            XCTAssertEqual(model.settingsScrollPosition.wrappedValue,
                           WiltedMacSettingsSection(savedAnchor: anchor).rawValue, anchor)
        }
        for section in WiltedMacSettingsSection.allCases {
            model.settingsSection = section
            XCTAssertEqual(model.settingsTab, WiltedMacSettingsTab(section: section), section.rawValue)
            model.scrollAnchor(for: .settings).wrappedValue = "settings-" + section.rawValue
            XCTAssertEqual(model.settingsScrollPosition.wrappedValue, section.rawValue)
            XCTAssertEqual(model.settingsTab, WiltedMacSettingsTab(section: section))
        }
    }

    func testScrollingAcrossSectionsUpdatesTheSelectedTab() {
        let model = settingsModel()

        for section in WiltedMacSettingsSection.allCases {
            model.settingsScrollPosition.wrappedValue = section.rawValue
            XCTAssertEqual(model.settingsSection, section)
            XCTAssertEqual(model.settingsTab, WiltedMacSettingsTab(section: section))
            XCTAssertEqual(model.scrollAnchor(for: .settings).wrappedValue, section.rawValue)
        }
    }

    func testManualScrollMovesThroughTheWholeSettingsPageAndUpdatesTheTab() async throws {
        let model = await WiltedMacHeadless.model(self, ["--wilted-ui-fixture-ready"])
        model.selectedNavigation = .settings
        model.settingsSection = .general
        let size = CGSize(width: 1_000, height: 720)
        let host = NSHostingView(rootView: WiltedMacSettingsView(model: model)
            .environment(\.colorScheme, .light).frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = WiltedMacHeadless.offscreenWindow(hosting: host)
        defer { withExtendedLifetime(window) {} }
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        func descendants(of view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants(of: $0) }
        }
        let scrollView = try XCTUnwrap(descendants(of: host).compactMap { $0 as? NSScrollView }.max {
            ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0)
        })
        let documentView = try XCTUnwrap(scrollView.documentView)
        let clipView = scrollView.contentView
        let initialOrigin = clipView.bounds.origin
        let distance = max(0, documentView.bounds.height - clipView.bounds.height)
        XCTAssertGreaterThan(distance, 0, "all settings sections extend beyond the viewport")
        let targetY = documentView.isFlipped
            ? documentView.bounds.minY + distance
            : documentView.bounds.minY
        clipView.scroll(to: NSPoint(x: documentView.bounds.minX, y: targetY))
        scrollView.reflectScrolledClipView(clipView)
        window.displayIfNeeded()
        host.layoutSubtreeIfNeeded()

        XCTAssertNotEqual(clipView.bounds.origin, initialOrigin, "the settings content actually scrolls")
        let selectedTabUpdated = await WiltedMacHeadless.eventually("selected tab follows the settings scroll") {
            model.settingsTab == .libraryAndSync
        }
        XCTAssertTrue(selectedTabUpdated)
        await model.close()
    }

    func testTabSelectionTargetsItsFirstSectionAndRestores() {
        let preferences = WiltedMacTestPreferences.ephemeral()
        let model = settingsModel(preferences: preferences)

        for tab in WiltedMacSettingsTab.allCases {
            model.settingsTab = tab
            XCTAssertEqual(model.settingsScrollPosition.wrappedValue, tab.sections[0].rawValue)
            XCTAssertEqual(settingsModel(preferences: preferences).settingsSection, tab.sections[0])
        }
    }

    func testProviderJumpRestoresAndReturningToTopShowsGeneral() {
        let model = settingsModel()

        model.settingsSection = .providers
        XCTAssertEqual(model.settingsTab, .adsAndProviders)
        XCTAssertEqual(model.scrollAnchor(for: .settings).wrappedValue, "providers")

        model.settingsScrollPosition.wrappedValue = "destination-top"
        XCTAssertNil(model.scrollAnchor(for: .settings).wrappedValue)
        XCTAssertEqual(model.settingsTab, .listening)

        model.settingsSection = .providers
        XCTAssertEqual(model.scrollAnchor(for: .settings).wrappedValue, "providers")
        XCTAssertEqual(model.settingsTab, .adsAndProviders)
    }

    func testClearedSettingsAnchorStartsAtTopWithoutSavingADefaultTab() {
        let model = settingsModel()
        XCTAssertNil(model.scrollAnchor(for: .settings).wrappedValue)
        XCTAssertEqual(model.settingsScrollPosition.wrappedValue, "destination-top")

        model.settingsScrollPosition.wrappedValue = "destination-top"

        XCTAssertNil(model.scrollAnchor(for: .settings).wrappedValue)
        XCTAssertEqual(model.settingsTab, .listening)
    }

    func testProviderJumpRendersTheProvidersSection() async throws {
        let model = settingsModel()
        model.settingsSection = .providers
        let size = CGSize(width: 900, height: 800)
        let host = NSHostingView(rootView: WiltedMacSettingsView(model: model)
            .environment(\.colorScheme, .light).frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = WiltedMacHeadless.offscreenWindow(hosting: host)
        defer { withExtendedLifetime(window) {} }

        func visibleText() throws -> [String] {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return try WiltedMacHeadless.recognizedLines(in: bitmap).map(\.text)
        }

        XCTAssertEqual(model.settingsTab, .adsAndProviders)
        let providerControlsVisible = await WiltedMacHeadless.eventually("provider section renders after restoration") {
            (try? visibleText().contains(where: { $0.localizedCaseInsensitiveContains("Check all") })) ?? false
        }
        XCTAssertTrue(providerControlsVisible, "The Providers section did not appear after the section jump")
        await model.close()
    }

    func testSectionJumpPlacesHeadingImmediatelyBelowTabs() async throws {
        let model = settingsModel()
        model.settingsSection = .providers
        let size = CGSize(width: 900, height: 700)
        let host = NSHostingView(rootView: WiltedMacSettingsView(model: model)
            .environment(\.colorScheme, .light).frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = WiltedMacHeadless.offscreenWindow(hosting: host)
        defer { withExtendedLifetime(window) {} }

        func renderedLines() throws -> [(text: String, top: CGFloat)] {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return try WiltedMacHeadless.recognizedLines(in: bitmap)
        }

        func assertHeading(_ title: String, line: UInt = #line) async throws {
            let atTop = await WiltedMacHeadless.eventually("\(title) scrolls directly below the tabs", file: #filePath, line: line) {
                guard let lines = try? renderedLines() else { return false }
            // Vision reliably reads only the selected (highlighted) tab, so measure from that one.
            func reading(_ text: String) -> (text: String, top: CGFloat)? {
                lines.first { $0.text.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(text) == .orderedSame }
            }
                guard let heading = reading(title), let tab = reading(model.settingsTab.title) else { return false }
            let gap = (heading.top - tab.top) * size.height
                return gap > 0 && gap < 50
            }
            XCTAssertTrue(atTop, "Expected \(title) directly below the tabs", line: line)
        }

        try await assertHeading("Providers")
        model.settingsSection = .preparing
        try await assertHeading("Preparing")
        // Give the tab's first-section request one layout pass, then immediately supersede it.
        model.settingsTab = .adsAndProviders
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        model.settingsSection = .providers
        try await assertHeading("Providers")
        // A jump within the open tab moves too.
        model.settingsSection = .ads
        try await assertHeading("Ads")
        model.settingsSection = .providers
        try await assertHeading("Providers")
        await model.close()
    }

    func testFourTabsAreVisibleAtTheNarrowestSupportedWindowWidth() throws {
        let model = settingsModel()
        let narrowWindowWidth = WiltedMacShellLayout.windowMinimumWidth() - WiltedMacShellLayout.railWidth
        let text = try WiltedMacHeadless.recognizedText(
            WiltedMacSettingsView(model: model).environment(\.wiltedTextScale, .standard),
            size: CGSize(width: narrowWindowWidth, height: 720)
        )
        for tab in WiltedMacSettingsTab.allCases {
            XCTAssertTrue(text.contains(where: { $0.localizedCaseInsensitiveContains(tab.title) }),
                          "The \(tab.title) tab is clipped at the minimum window width")
        }

        for scale in WiltedTheme.TextScale.allCases {
            let font = NSFont.monospacedSystemFont(ofSize: 12 * scale.multiplier, weight: .medium)
            let labelsWidth = WiltedMacSettingsTab.allCases.reduce(CGFloat.zero) { width, tab in
                width + (tab.title as NSString).size(withAttributes: [.font: font]).width
            }
            let requiredWidth = labelsWidth
                + CGFloat(WiltedMacSettingsTab.allCases.count) * WiltedTheme.Spacing.xSmall * 2
                + CGFloat(WiltedMacSettingsTab.allCases.count - 1) * WiltedTheme.Spacing.xSmall
                + WiltedTheme.Spacing.small * 2
            let availableWidth = WiltedMacShellLayout.windowMinimumWidth(scale: scale) - WiltedMacShellLayout.railWidth
            XCTAssertLessThanOrEqual(requiredWidth, availableWidth, "Tabs exceed the minimum width at \(scale)")
        }
    }
}
