import AppKit
import SwiftUI
import WiltedDomain
import WiltedLibrary
import WiltedProducer
import XCTest
@testable import WiltedMac

extension WiltedPixelSnapshotTests {
    private func snapshotDeviceAnnouncementDate() -> Date {
        var components = DateComponents()
        components.year = 2020
        components.month = 1
        components.day = 15
        components.hour = 12
        return Calendar.current.date(from: components) ?? Date(timeIntervalSince1970: 1_579_089_600)
    }

    func testGeneralSettingsPixels() async {
        await captureSettingsTab(.listening, kind: "settings-tab-listening-top", testName: "testGeneralSettingsPixels")
    }

    func testNewEpisodesSettingsPixels() async {
        await captureSettingsTab(.feedsAndReports, kind: "settings-tab-feeds-reports-top", testName: "testNewEpisodesSettingsPixels")
    }

    func testPreparingSettingsPixels() async {
        await captureSettingsSection(.preparing, kind: "settings-tab-listening-scrolled", testName: "testPreparingSettingsPixels")
    }

    func testAdsSettingsPixels() async {
        await captureSettingsTab(.adsAndProviders, kind: "settings-tab-ads-providers-top", testName: "testAdsSettingsPixels")
    }

    func testProvidersSettingsPixels() async {
        let model = WiltedMacModel(arguments: ["--wilted-ui-fixture-ready"],
            stateDirectoryOverride: wiltedTemporaryDirectory("settings-providers"),
            preferences: WiltedMacTestPreferences.ephemeral())
        model.providers.saveKey("fixture-provider-key", for: .openAIKey)
        await model.waitForLifetimeStatisticsForTesting()
        let content = WiltedMacProvidersSettingsView(model: model)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(WiltedTheme.color(.page, scheme: .light))
        let image = render(content,
            variant: .init(appearance: .light, dynamicType: .standard, reduceMotion: false),
            size: CGSize(width: 760, height: 700))
        assertSnapshot(image,
            named: WiltedSnapshotContract.shellName(kind: "settings-providers", appearance: .light),
            testName: "testProvidersSettingsPixels")
        await model.close()
    }

    func testAdsProvidersScrolledSettingsPixels() async {
        await captureSettingsSection(.providers, kind: "settings-tab-ads-providers-scrolled",
            testName: "testAdsProvidersScrolledSettingsPixels")
    }

    func testReportsSettingsPixels() async {
        await captureSettingsSection(.reports, kind: "settings-tab-feeds-reports-scrolled", testName: "testReportsSettingsPixels")
    }

    func testDevicesSettingsPixels() async {
        await captureSettingsTab(.libraryAndSync, kind: "settings-tab-library-sync-top", testName: "testDevicesSettingsPixels")
    }

    func testDevicesSettingsWithSyntheticDeviceRowsPixels() async {
        let model = WiltedMacModel(arguments: ["--wilted-ui-fixture-ready"],
            stateDirectoryOverride: wiltedTemporaryDirectory("settings-devices-rows"),
            preferences: WiltedMacTestPreferences.ephemeral())
        model.selectedNavigation = .settings
        model.settingsSection = .devices
        await model.waitForLifetimeStatisticsForTesting()
        model.librarySyncActivity.devices = [
            WiltedMacLinkedDevice(deviceID: "snapshot-phone", kind: "iPhone", isLinked: true, inFlight: [],
                displayName: "Kitchen iPhone", lastAnnouncedAt: snapshotDeviceAnnouncementDate()),
            WiltedMacLinkedDevice(deviceID: "snapshot-device", kind: nil, isLinked: false, inFlight: [],
                displayName: nil, lastAnnouncedAt: nil)
        ]
        let image = render(WiltedMacRootView(model: model),
            variant: .init(appearance: .light, dynamicType: .standard, reduceMotion: false), size: windowCanvas)
        assertSnapshot(image,
            named: WiltedSnapshotContract.shellName(kind: "section-devices-synthetic-rows", appearance: .light),
            testName: "testDevicesSettingsWithSyntheticDeviceRowsPixels")
        await model.close()
    }

    func testDirectDownloadsDeviceMenuPixels() throws {
        let device = WiltedMacLinkedDevice(
            deviceID: "snapshot-phone", kind: "iPhone", isLinked: true, inFlight: [],
            isDirectDownloadsStopped: true, displayName: "Study iPhone",
            lastAnnouncedAt: snapshotDeviceAnnouncementDate())
        let row = try XCTUnwrap(WiltedMacLibrarySyncStatus.deviceRows([device]).first)
        let content = WiltedMacDeviceDownloadsMenu(row: row, macEnabled: true, onStop: {}, onRename: {}, onRemove: {})
            .padding(WiltedTheme.Spacing.small)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(WiltedTheme.color(.card, scheme: .light))
        let image = render(content,
            variant: .init(appearance: .light, dynamicType: .standard, reduceMotion: false),
            size: CGSize(width: 360, height: 210))
        assertSnapshot(image,
            named: WiltedSnapshotContract.shellName(kind: "direct-downloads-device-menu", appearance: .light),
            testName: "testDirectDownloadsDeviceMenuPixels")
    }

    func testDeviceRemovalConfirmationPixels() {
        let content = WiltedMacDeviceRemovalConfirmation(
            deviceName: "Travel iPhone", transferInFlight: true, onCancel: {}, onRemove: {},
            isRemoving: false, errorMessage: nil)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .background(WiltedTheme.color(.card, scheme: .light))
        let image = render(content,
            variant: .init(appearance: .light, dynamicType: .standard, reduceMotion: false),
            size: CGSize(width: 520, height: 260))
        assertSnapshot(image,
            named: WiltedSnapshotContract.shellName(kind: "device-removal-confirmation", appearance: .light),
            testName: "testDeviceRemovalConfirmationPixels")
    }

    func testAboutSettingsPixels() async {
        await captureSettingsSection(.about, kind: "settings-tab-library-sync-scrolled", testName: "testAboutSettingsPixels")
    }

    func testSettingsTabScrollTargetsRenderTheirSections() async throws {
        let model = WiltedMacModel(arguments: ["--wilted-ui-fixture-ready"],
            stateDirectoryOverride: wiltedTemporaryDirectory("settings-tab-scroll"),
            preferences: WiltedMacTestPreferences.ephemeral())
        model.selectedNavigation = .settings
        await model.waitForLifetimeStatisticsForTesting()
        let variants = [
            (tab: WiltedMacSettingsTab.feedsAndReports, scrolled: WiltedMacSettingsSection.reports, name: "Feeds & Reports"),
            (tab: WiltedMacSettingsTab.adsAndProviders, scrolled: WiltedMacSettingsSection.providers, name: "Ads & Providers")
        ]

        for pair in variants {
            model.settingsTab = pair.tab
            let topImage = render(WiltedMacRootView(model: model),
                variant: .init(appearance: .light, dynamicType: .standard, reduceMotion: false), size: windowCanvas, inWindow: true)
            model.settingsSection = pair.scrolled
            let scrolledImage = render(WiltedMacRootView(model: model),
                variant: .init(appearance: .light, dynamicType: .standard, reduceMotion: false), size: windowCanvas, inWindow: true)
            let topBitmap = try XCTUnwrap(topImage.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            let scrolledBitmap = try XCTUnwrap(scrolledImage.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            XCTAssertLessThan(pixelPrecision(expected: topBitmap, actual: scrolledBitmap), 0.99,
                "The scrolled \(pair.name) capture must show its second section.")
        }
        await model.close()
    }

    private func captureSettingsTab(_ tab: WiltedMacSettingsTab, kind: String, testName: String) async {
        await captureSettingsPosition(kind: kind, testName: testName) { $0.settingsTab = tab }
    }

    private func captureSettingsSection(_ section: WiltedMacSettingsSection, kind: String, testName: String) async {
        await captureSettingsPosition(kind: kind, testName: testName) { $0.settingsSection = section }
    }

    private func captureSettingsPosition(
        kind: String,
        testName: String,
        select: (WiltedMacModel) -> Void
    ) async {
        // The store stamps tracking start at creation, so the About card would print today's date.
        let trackingStart = snapshotDeviceAnnouncementDate()
        let live = WiltedMacStatisticsOperations.live
        let pinnedStatistics = WiltedMacStatisticsOperations(
            summary: { store in
                var summary = try await live.summary(store)
                summary.trackingStartedAt = trackingStart
                return summary
            },
            rebuild: { store, progress in
                var summary = try await live.rebuild(store, progress)
                summary.trackingStartedAt = trackingStart
                return summary
            }
        )
        let model = WiltedMacModel(arguments: ["--wilted-ui-fixture-ready"],
            stateDirectoryOverride: wiltedTemporaryDirectory("settings-section"),
            statisticsOperations: pinnedStatistics,
            preferences: WiltedMacTestPreferences.ephemeral())
        model.selectedNavigation = .settings
        select(model)
        await model.waitForLifetimeStatisticsForTesting()
        // A 1% pixel tolerance would not notice the date line drifting back to today.
        XCTAssertEqual(model.statisticsState.summary?.trackingStartedAt, trackingStart, testName)
        let image = render(WiltedMacRootView(model: model),
            variant: .init(appearance: .light, dynamicType: .standard, reduceMotion: false), size: windowCanvas, inWindow: true)
        assertSnapshot(image, named: WiltedSnapshotContract.shellName(kind: kind, appearance: .light),
            testName: testName)
        await model.close()
    }

    // MARK: Reports settings

    /// The Reports section with interruptions on, the daily report on and typed coordinates in use.
    func testReportsSettingsPixelBaselines() async throws {
        for appearance in WiltedAppearance.allCases {
            let model = WiltedMacModel(
                arguments: ["--wilted-ui-fixture-ready"], stateDirectoryOverride: wiltedTemporaryDirectory("reports-pixel"),
                preferences: WiltedMacTestPreferences.ephemeral())
            model.updateAutomationSettings { current in
                current.updatingReports {
                    $0.interruptionsEnabled = true
                    $0.reportEnabled = true
                    $0.typedLatitude = 38.9
                    $0.typedLongitude = -77.04
                    $0.nwsContact = "listener@example.test"
                }
            }
            let location = WiltedLocationProvider(
                manager: PixelFakeLocationManager(), wifi: PixelFakeWiFi(),
                typedCoordinates: model.automationSettings.typedCoordinates)
            let content = WiltedMacReportsCard(model: model, location: location, startsExpanded: true)
                .padding(WiltedTheme.Spacing.large)
                .environment(\.wiltedTextScale, model.textScale)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(WiltedTheme.color(.page, scheme: appearance == .dark ? .dark : .light))
            let image = render(
                content, variant: .init(appearance: appearance, dynamicType: .standard, reduceMotion: false),
                size: CGSize(width: 760, height: 560))
            let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            XCTAssertGreaterThan(distinctColorCount(in: bitmap), 8, "the Reports section drew")
            assertSnapshot(
                image, named: WiltedSnapshotContract.shellName(kind: "settings-reports", appearance: appearance),
                testName: "testReportsSettingsPixelBaselines")
        }

        for state in ["not-ready", "ready"] {
            let library = try await AccountingLibrary.make(
                in: wiltedTemporaryDirectory("reports-pixel-\(state)"))
            let model = library.model
            let location = WiltedLocationProvider(
                manager: ReadinessLocationManager(authorization: .denied), wifi: ReadinessWiFi())
            let hub = WiltedMacBulletinHub(
                model: model, location: location, makeSpeaker: { ReadinessSpeaker() },
                makeRouteSource: { ReadinessRoute() })
            model.installBulletinHubForTesting(hub)

            if state == "ready" {
                let store = try XCTUnwrap(model.store)
                let createdAt = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
                let feed = try ArticleFeed(
                    canonicalURL: try XCTUnwrap(URL(string: "https://feeds.example.test/reports-pixel.xml")),
                    title: "Reports snapshot news", createdAt: createdAt)
                try await store.save(articleFeed: feed)
                try await store.save(subscription: PodcastSubscription(feedID: feed.itemID, subscribedAt: createdAt))
                try await store.save(isNews: true, feedID: feed.itemID)
            }

            model.updateAutomationSettings { current in
                current.updatingReports {
                    $0.interruptionsEnabled = true
                    $0.headlinesEnabled = true
                    $0.alertsEnabled = true
                    $0.reportEnabled = true
                    $0.typedLatitude = 38.9
                    $0.typedLongitude = -77.04
                    $0.nwsContact = "listener@example.test"
                }
            }
            await hub.refreshNewsSourceReadiness()
            XCTAssertEqual(hub.readiness.lines, state == "ready" ? [.ready] : [.news])

            for appearance in WiltedAppearance.allCases {
                let content = WiltedMacReportsCard(model: model, location: location)
                    .padding(WiltedTheme.Spacing.large)
                    .environment(\.wiltedTextScale, model.textScale)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .background(WiltedTheme.color(
                        .page, scheme: appearance == .dark ? .dark : .light))
                let image = render(
                    content, variant: .init(appearance: appearance, dynamicType: .standard, reduceMotion: false),
                    size: CGSize(width: 760, height: 560))
                let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
                XCTAssertGreaterThan(distinctColorCount(in: bitmap), 8, "the Reports readiness state drew")
                assertSnapshot(
                    image,
                    named: WiltedSnapshotContract.shellName(kind: "settings-reports-\(state)", appearance: appearance),
                    testName: "testReportsSettingsPixelBaselines")
            }
            await model.close()
        }
    }

    /// Settings is scrollable at window scale, so this focused render check
    /// guards against the automation card collapsing the destination to a
    /// blank surface without requiring a new unreviewed pixel baseline.
    func testSettingsAutomationSurfaceRendersAtWindowScale() throws {
        for appearance in WiltedAppearance.allCases {
            let variant = WiltedVisualVariant(
                appearance: appearance,
                dynamicType: .standard,
                reduceMotion: false
            )
            let model = WiltedMacModel(
                arguments: ["--wilted-ui-fixture-ready"],
                stateDirectoryOverride: wiltedTemporaryDirectory("fixture"),
                preferences: WiltedMacTestPreferences.ephemeral()
            )
            model.selectedNavigation = .settings
            model.settingsSection = .newEpisodes
            let image = render(WiltedMacRootView(model: model), variant: variant, size: windowCanvas)
            let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            let detail = NSRect(x: 260, y: 0, width: bitmap.pixelsWide - 260, height: bitmap.pixelsHigh)
            XCTAssertGreaterThan(
                distinctColorCount(in: bitmap, region: detail), 8,
                "Settings automation surface is blank in \(appearance.rawValue) mode."
            )
        }
    }
}

@MainActor
private final class PixelFakeLocationManager: WiltedLocationManaging {
    var authorization = WiltedLocationAuthorization.authorized
    var onAuthorizationChange: (() -> Void)?
    var onFix: ((Double, Double) -> Void)?
    var onFailure: (() -> Void)?
    func requestPermission() {}
    func requestOneFix() {}
}

@MainActor
private final class PixelFakeWiFi: WiltedWiFiPowerReading {
    var isPoweredOn = false
}
