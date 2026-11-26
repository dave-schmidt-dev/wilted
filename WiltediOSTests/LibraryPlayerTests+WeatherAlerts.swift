import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltediOS

@MainActor
final class LibraryPlayerWeatherAlertTests: XCTestCase {
    private let suite = "library-weather-alert-tests"
    private var defaults: UserDefaults!

    override func setUp() async throws {
        await HostedAccessibility.prepare()
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func testWeatherAlertNowPlayingCardRetainsOriginalAfterSpeech() async throws {
        let now = Date()
        let source = "Official NWS headline.\n\nStay low or go below, and make sure all on board are wearing life jackets."
        let bulletin = try Bulletin(
            id: "urn:oid:2.49.0.1.840.0.10001", kind: .alert,
            text: "Severe Special Marine Warning for Hawk Channel. It ends Wednesday, November 25 at 10:00 PM EST. Stay low or go below.",
            severity: .severe, issuedAt: now, expiresAt: now.addingTimeInterval(600),
            link: URL(string: "https://api.weather.gov/alerts/urn:oid:2.49.0.1.840.0.10001"), originalText: source)
        let channel = try LibraryBulletins(
            alertsEnabled: true, headlinesEnabled: false, headlines: [], updatedAt: now)
        let rig = makeInterruptionRig(channel: channel, defaults: defaults)
        await rig.play(at: 42)
        await rig.controller.syncTick()
        rig.controller.alertArrived(bulletin)
        XCTAssertEqual(rig.controller.nowPlayingWeatherAlert?.id, bulletin.id)

        rig.crossAdBreak()
        XCTAssertEqual(rig.controller.activeSpokenWeatherAlert?.id, bulletin.id)
        rig.speaker.completeSpeech()
        XCTAssertNil(rig.controller.activeSpokenWeatherAlert)
        XCTAssertEqual(rig.controller.nowPlayingWeatherAlert?.originalText, source)

        let host = HostedView(LibraryNowPlayingWeatherAlertCard(controller: rig.controller))
        XCTAssertEqual(host.element("wilted-player-weather-alert-state")?.label, "Last weather alert read")
        XCTAssertTrue(host.element("wilted-player-weather-alert-summary")?.label?.contains("Special Marine Warning") == true)
        XCTAssertTrue(host.element("wilted-player-weather-alert-original-toggle")?.activate() == true)
        host.settle()
        XCTAssertEqual(host.element("wilted-player-weather-alert-original-text")?.label, source)
        XCTAssertNotNil(host.element("wilted-player-weather-alert-open-official"))
    }

    func testWeatherAlertWatchdogUsesRenderedDuration() async throws {
        let recorder = InterruptionWatchdogRecorder()
        let channel = try LibraryBulletins(
            alertsEnabled: true, headlinesEnabled: false, headlines: [], updatedAt: Date())
        let rig = makeInterruptionRig(
            channel: channel, defaults: defaults,
            sleep: { duration in
                await recorder.record(duration)
                try await Task.sleep(for: .seconds(3600))
            })
        await rig.play(at: 42)
        await rig.controller.syncTick()
        let bulletin = try Bulletin(
            id: "weather-long", kind: .alert, text: "An alert with a long cached audio clip.",
            severity: .severe, issuedAt: Date(), expiresAt: Date().addingTimeInterval(3_600))
        rig.speaker.expectedPlaybackDuration = 240
        rig.controller.alertArrived(bulletin)
        rig.crossAdBreak()

        var actual: Duration?
        for _ in 0..<100 {
            actual = await recorder.first()
            if actual != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(actual, .seconds(255))
        XCTAssertTrue(rig.player.isHoldingForSpeech, "the watchdog allows the whole cached clip plus a safety margin")
    }
}
