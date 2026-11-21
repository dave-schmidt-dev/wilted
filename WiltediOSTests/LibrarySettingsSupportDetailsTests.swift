import SwiftUI
import UIKit
import WiltedCloudKitLibrary
import WiltedLibrary
import XCTest
@testable import WiltediOS

/// Settings shows no device ID, sync detail, voice log or iCloud request counts by default. A long
/// press on Version (or its accessibility action) shows them as support details, and again hides them.
@MainActor
final class LibrarySettingsSupportDetailsTests: XCTestCase {
    private let hiddenIdentifiers = [
        "wilted-library-settings-device-id", "wilted-library-settings-voice-routing-log",
        "wilted-library-settings-sync-diagnostics", "wilted-library-settings-sync-detail",
        "wilted-library-settings-support-details", "wilted-library-settings-diagnostics-disclosure",
    ]
    private let hiddenWords = ["Device and sync details", "Sync detail", "Fetch time reports", "requests in the last"]
    private var suite: String!

    override func setUp() async throws {
        await HostedAccessibility.prepare()
        suite = "library-settings-support-\(UUID().uuidString)"
    }

    override func tearDown() async throws {
        UserDefaults().removePersistentDomain(forName: suite)
    }

    private func hostedSettings(dark: Bool = false) async -> HostedView<LibrarySettingsView> {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let model = LibraryAppModel(
            transport: InMemoryLibraryTransport(deviceID: "phone-support-id", server: InMemoryLibraryServer(writerDeviceID: "mac")),
            deviceID: "phone-support-id", deviceKind: "iPhone",
            preferences: UserDefaults(suiteName: suite)!,
            now: { base }, timeZone: TimeZone(identifier: "UTC")!,
            operationCounters: CloudKitOperationCounters(clock: { base }, startLoggingTask: false))
        await model.refresh()
        let settings = LibrarySettingsStore(defaults: UserDefaults(suiteName: suite)!)
        return HostedView(LibrarySettingsView(settings: settings, model: model, playingID: nil, onDone: {}),
                          size: CGSize(width: 390, height: 2400), dark: dark)
    }

    private func picture(_ hosted: HostedView<LibrarySettingsView>, named name: String) {
        let renderer = UIGraphicsImageRenderer(bounds: hosted.window.bounds)
        let image = renderer.image { context in hosted.window.layer.render(in: context.cgContext) }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func assertHidden(_ hosted: HostedView<LibrarySettingsView>, file: StaticString = #filePath, line: UInt = #line) {
        let elements = hosted.elements()
        for id in hiddenIdentifiers {
            XCTAssertNil(hosted.element(id), "\(id) must not show by default", file: file, line: line)
        }
        for word in hiddenWords {
            XCTAssertFalse(elements.contains { ($0.label ?? "").contains(word) }, "\"\(word)\" must not show by default",
                           file: file, line: line)
        }
    }

    func testSupportDetailsAreHiddenByDefaultAndALongPressOnVersionShowsThem() async throws {
        let hosted = await hostedSettings()
        XCTAssertNotNil(hosted.element(LibrarySettingsFormat.versionIdentifier), "the version still shows")
        assertHidden(hosted)
        picture(hosted, named: "iphone-settings-default-light")

        let version = try XCTUnwrap(hosted.elements().first {
            $0.customActionNames.contains(LibrarySettingsFormat.showSupportDetailsAction)
        }, "Version offers the hidden action")
        XCTAssertTrue(version.perform(customAction: LibrarySettingsFormat.showSupportDetailsAction))
        hosted.settle()
        XCTAssertEqual(hosted.element(LibrarySettingsFormat.deviceIdentifier)?.label, "phone-support-id")
        XCTAssertNotNil(hosted.element(LibrarySettingsFormat.voiceRoutingLogIdentifier))
        XCTAssertEqual(hosted.element(LibrarySettingsFormat.syncDiagnosticsIdentifier)?.label,
                       "0 requests in the last 5 minutes · no limits since launch")
        XCTAssertNil(hosted.element(LibrarySettingsFormat.syncDetailIdentifier), "the sync detail row is gone")
        picture(hosted, named: "iphone-settings-support-shown-light")

        let hide = try XCTUnwrap(hosted.elements().first {
            $0.customActionNames.contains(LibrarySettingsFormat.hideSupportDetailsAction)
        })
        XCTAssertTrue(hide.perform(customAction: LibrarySettingsFormat.hideSupportDetailsAction))
        hosted.settle()
        assertHidden(hosted)
    }

    func testDarkDefaultPicture() async {
        let hosted = await hostedSettings(dark: true)
        assertHidden(hosted)
        picture(hosted, named: "iphone-settings-default-dark")
    }
}
