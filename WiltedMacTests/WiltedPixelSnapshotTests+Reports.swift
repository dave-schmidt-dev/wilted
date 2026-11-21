import AppKit
import SwiftUI
import WiltedDomain
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
        await captureSettingsSection(.general, testName: "testGeneralSettingsPixels")
    }

    func testNewEpisodesSettingsPixels() async {
        await captureSettingsSection(.newEpisodes, testName: "testNewEpisodesSettingsPixels")
    }

    func testPreparingSettingsPixels() async {
        await captureSettingsSection(.preparing, testName: "testPreparingSettingsPixels")
    }

    func testAdsSettingsPixels() async {
        await captureSettingsSection(.ads, testName: "testAdsSettingsPixels")
    }

    func testReportsSettingsPixels() async {
        await captureSettingsSection(.reports, testName: "testReportsSettingsPixels")
    }

    func testDevicesSettingsPixels() async {
        await captureSettingsSection(.devices, testName: "testDevicesSettingsPixels")
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
        await captureSettingsSection(.about, testName: "testAboutSettingsPixels")
    }

    private func captureSettingsSection(_ section: WiltedMacSettingsSection, testName: String) async {
        let model = WiltedMacModel(arguments: ["--wilted-ui-fixture-ready"],
            stateDirectoryOverride: wiltedTemporaryDirectory("settings-section"),
            preferences: WiltedMacTestPreferences.ephemeral())
        model.selectedNavigation = .settings
        model.settingsSection = section
        await model.waitForLifetimeStatisticsForTesting()
        let image = render(WiltedMacRootView(model: model),
            variant: .init(appearance: .light, dynamicType: .standard, reduceMotion: false), size: windowCanvas)
        assertSnapshot(image, named: WiltedSnapshotContract.shellName(kind: "section-" + section.rawValue, appearance: .light),
            testName: testName)
        await model.close()
    }

    // MARK: Reports settings

    /// The Reports section with interruptions on, the daily report on and typed coordinates in use.
    func testReportsSettingsPixelBaselines() throws {
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
