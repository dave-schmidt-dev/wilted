import AppKit
import SwiftUI
import XCTest
@testable import WiltedMac

@MainActor
final class WiltedMacSettingsSectionTests: XCTestCase {
    func testPhoneAndGenericDeviceEachExposeAMenuButton() throws {
        let rows = WiltedMacLibrarySyncStatus.deviceRows([
            .init(deviceID: "fixture-a", kind: "iPhone", isLinked: true, inFlight: []),
            .init(deviceID: "fixture-b", kind: nil, isLinked: false, inFlight: [])
        ])
        XCTAssertEqual(rows.map(\.id), ["fixture-a", "fixture-b"])

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

    func testLegacyAnchorsAndAllNewSelectionsRestoreAcrossLaunches() {
        let preferences = WiltedMacTestPreferences.ephemeral()
        func launch() -> WiltedMacModel { WiltedMacModel(arguments: [], preferences: preferences) }
        let first = launch()
        XCTAssertEqual(first.settingsSection, .general)
        XCTAssertEqual(WiltedMacSettingsSection.allCases.map(\.title),
                       ["General", "New episodes", "Preparing", "Ads", "Reports", "Devices", "About"])
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
    }
}
