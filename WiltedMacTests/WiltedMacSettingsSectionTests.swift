import XCTest
@testable import WiltedMac

@MainActor
final class WiltedMacSettingsSectionTests: XCTestCase {
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
